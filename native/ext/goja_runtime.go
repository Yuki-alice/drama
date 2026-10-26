package ext

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"sync"

	"crypto/md5"
	"crypto/sha3"

	"github.com/andybalholm/cascadia"
	"github.com/dop251/goja"
)

// Registry 构造绑定宿主能力的 goja 运行时。
// callCtx 保存当前调用的 context：Extension 串行执行同一源的脚本，
// 因此单个 Registry 字段即可让 hg.fetch 响应取消。
type Registry struct {
	host    Host
	callCtx context.Context
}

func NewRegistry(host Host) *Registry { return &Registry{host: host} }

// setCallContext 由 gojaRuntime 在每次调用前写入。
func (r *Registry) setCallContext(ctx context.Context) { r.callCtx = ctx }

// callContext 返回本次脚本调用的 context；未注入时退回 Background。
func (r *Registry) callContext() context.Context {
	if r.callCtx != nil {
		return r.callCtx
	}
	return context.Background()
}

// NewRuntime 编译扩展脚本并注入宿主对象。
func (r *Registry) NewRuntime(manifest Manifest, code string) (Runtime, error) {
	vm := goja.New()
	vm.SetFieldNameMapper(goja.UncapFieldNameMapper())
	console := vm.NewObject()
	_ = console.Set("log", func(args ...goja.Value) {
		r.host.Log(manifest.ID, consoleText(args))
	})
	_ = vm.Set("console", console)
	_ = vm.Set("hg", r.hostObject(manifest.ID, vm))
	kitProgram, err := goja.Compile("hgkit.js", hostKitSource, false)
	if err != nil {
		return nil, fmt.Errorf("扩展工具库无法编译: %w", err)
	}
	if _, err := vm.RunProgram(kitProgram); err != nil {
		return nil, fmt.Errorf("扩展工具库初始化失败: %w", err)
	}
	program, err := goja.Compile(manifest.ID+".js", code, false)
	if err != nil {
		return nil, err
	}
	return &gojaRuntime{vm: vm, program: program, source: manifest.ID, host: r.host, registry: r}, nil
}

type gojaRuntime struct {
	vm       *goja.Runtime
	program  *goja.Program
	source   string
	host     Host
	registry *Registry
}

func (r *gojaRuntime) RunProgram() error {
	if _, err := r.vm.RunProgram(r.program); err != nil {
		return err
	}
	source := r.vm.Get("source")
	if source == nil || goja.IsNull(source) || goja.IsUndefined(source) {
		return errors.New("source 契约对象缺失")
	}
	if _, ok := source.(*goja.Object); !ok {
		return errors.New("source 契约必须是对象")
	}
	return nil
}

// Call 执行 source.<method>；method 形如 "catalog"。
func (r *gojaRuntime) Call(method string, args []any) (any, error) {
	source := r.vm.Get("source")
	if source == nil {
		return nil, errors.New("source 契约对象缺失")
	}
	object, ok := source.(*goja.Object)
	if !ok {
		return nil, errors.New("source 契约必须是对象")
	}
	fn := object.Get(method)
	if fn == nil || goja.IsUndefined(fn) {
		return nil, fmt.Errorf("扩展未实现 %s", method)
	}
	callable, ok := goja.AssertFunction(fn)
	if !ok {
		return nil, fmt.Errorf("扩展的 %s 不是函数", method)
	}
	values := make([]goja.Value, 0, len(args))
	for _, arg := range args {
		values = append(values, r.vm.ToValue(arg))
	}
	// 以 source 对象作为 this 调用契约方法，符合扩展里的方法语义。
	result, err := callable(object, values...)
	if err != nil {
		return nil, err
	}
	return result.Export(), nil
}

func (r *gojaRuntime) Interrupt(reason error) { r.vm.Interrupt(reason) }

func (r *gojaRuntime) SetContext(ctx context.Context) { r.registry.setCallContext(ctx) }

// callContext 是 Registry.callContext 的就近转发；hg.fetch 与 Registry
// 共享同一份调用 context。
func (r *gojaRuntime) callContext() context.Context { return r.registry.callContext() }

// hostObject 构造 hg 宿主对象：网络、HTML、加密、存储与日志。
func (r *Registry) hostObject(source string, vm *goja.Runtime) *goja.Object {
	hg := vm.NewObject()
	_ = hg.Set("fetch", func(call goja.FunctionCall) goja.Value {
		url := strings.TrimSpace(toString(call.Argument(0)))
		if url == "" {
			panic(vm.NewGoError(errors.New("hg.fetch 需要 URL 参数")))
		}
		request, err := buildRequest(url, call.Argument(1).Export())
		if err != nil {
			panic(vm.NewGoError(err))
		}
		// 扩展网络调用使用请求的 context；VM 中断后阻塞在宿主的调用
		// 会随 context 取消返回，不会悬挂。
		response, err := r.host.Fetch(r.callContext(), source, request)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(fetchValue(vm, response))
	})
	_ = hg.Set("log", func(call goja.FunctionCall) goja.Value {
		r.host.Log(source, consoleText(call.Arguments))
		return goja.Undefined()
	})
	// fetchAll 并行取多个地址：js 单线程无法自行并发，而帝果、黄果旧版、
	// 黄果 AI 的目录是多分类聚合并行拉取后合并的，串行会成倍变慢。
	// 入参与返回顺序一一对应；单项失败时为 {error} 而非整体失败，
	// 让扩展能像原 Go 实现一样保留部分成功的结果。
	_ = hg.Set("fetchAll", func(call goja.FunctionCall) goja.Value {
		rows, ok := call.Argument(0).Export().([]any)
		if !ok {
			panic(vm.NewGoError(errors.New("hg.fetchAll 需要请求数组")))
		}
		if len(rows) > 32 {
			panic(vm.NewGoError(errors.New("hg.fetchAll 单次最多 32 个请求")))
		}
		requests := make([]Request, len(rows))
		for index, row := range rows {
			options, ok := row.(map[string]any)
			if !ok {
				panic(vm.NewGoError(errors.New("hg.fetchAll 每一项必须是 {url, options} 对象")))
			}
			address := strings.TrimSpace(nativeAnyText(options["url"]))
			if address == "" {
				panic(vm.NewGoError(errors.New("hg.fetchAll 每一项都需要 url")))
			}
			request, err := buildRequest(address, options["options"])
			if err != nil {
				panic(vm.NewGoError(err))
			}
			requests[index] = request
		}
		ctx := r.callContext()
		type outcome struct {
			response *Response
			err      error
		}
		results := make([]outcome, len(requests))
		slots := make(chan struct{}, 4)
		var group sync.WaitGroup
		for index, request := range requests {
			group.Add(1)
			go func(index int, request Request) {
				defer group.Done()
				select {
				case slots <- struct{}{}:
					defer func() { <-slots }()
				case <-ctx.Done():
					results[index] = outcome{err: ctx.Err()}
					return
				}
				response, err := r.host.Fetch(ctx, source, request)
				results[index] = outcome{response: response, err: err}
			}(index, request)
		}
		group.Wait()
		values := make([]any, len(results))
		for index, result := range results {
			if result.err != nil {
				values[index] = map[string]any{"error": result.err.Error()}
				continue
			}
			values[index] = fetchValue(vm, result.response)
		}
		return vm.ToValue(values)
	})
	_ = hg.Set("storage", storageObject(source, r.host, vm))
	_ = hg.Set("crypto", cryptoObject(vm))
	_ = hg.Set("html", htmlObject(vm))
	_ = hg.Set("url", urlObject(vm))
	return hg
}

// urlObject 提供 hg.url.parse：宿主 net/url 的安全封装。
// goja 无 WHATWG URL，扩展统一经此解析与归一化地址。
func urlObject(vm *goja.Runtime) *goja.Object {
	object := vm.NewObject()
	// encodeQuery：{k:v} → 表单编码串（goja 无 URLSearchParams）。
	_ = object.Set("encodeQuery", func(call goja.FunctionCall) goja.Value {
		exported, ok := call.Argument(0).Export().(map[string]any)
		if !ok {
			return vm.ToValue("")
		}
		values := url.Values{}
		for key, value := range exported {
			text := strings.TrimSpace(fmt.Sprintf("%v", value))
			if text != "" {
				values.Set(key, text)
			}
		}
		return vm.ToValue(values.Encode())
	})
	_ = object.Set("parse", func(call goja.FunctionCall) goja.Value {
		raw := strings.TrimSpace(toString(call.Argument(0)))
		if raw == "" || len(raw) > 8192 || strings.ContainsAny(raw, " \t\r\n") {
			return vm.ToValue(map[string]any{"valid": false})
		}
		parsed, err := url.Parse(raw)
		if err != nil || parsed.Host == "" {
			return vm.ToValue(map[string]any{"valid": false})
		}
		return vm.ToValue(map[string]any{
			"valid":    true,
			"protocol": parsed.Scheme,
			"host":     parsed.Host,
			"hostname": parsed.Hostname(),
			"path":     parsed.EscapedPath(),
			"query":    parsed.RawQuery,
			"href":     parsed.String(),
		})
	})
	return object
}

func storageObject(source string, host Host, vm *goja.Runtime) *goja.Object {
	storage := vm.NewObject()
	_ = storage.Set("get", func(call goja.FunctionCall) goja.Value {
		key := toString(call.Argument(0))
		values, err := host.StorageLoad(source)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(values[key])
	})
	_ = storage.Set("set", func(call goja.FunctionCall) goja.Value {
		key := toString(call.Argument(0))
		value := toString(call.Argument(1))
		values, err := host.StorageLoad(source)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		if value == "" {
			delete(values, key)
		} else {
			values[key] = value
		}
		if err := host.StorageSave(source, values); err != nil {
			panic(vm.NewGoError(err))
		}
		return goja.Undefined()
	})
	_ = storage.Set("keys", func(call goja.FunctionCall) goja.Value {
		values, err := host.StorageLoad(source)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		keys := make([]any, 0, len(values))
		for key := range values {
			keys = append(keys, key)
		}
		return vm.ToValue(keys)
	})
	return storage
}

func cryptoObject(vm *goja.Runtime) *goja.Object {
	crypto := vm.NewObject()
	_ = crypto.Set("md5hex", func(call goja.FunctionCall) goja.Value {
		sum := md5.Sum([]byte(toString(call.Argument(0))))
		return vm.ToValue(hex.EncodeToString(sum[:]))
	})
	_ = crypto.Set("sha256hex", func(call goja.FunctionCall) goja.Value {
		sum := sha256.Sum256([]byte(toString(call.Argument(0))))
		return vm.ToValue(hex.EncodeToString(sum[:]))
	})
	_ = crypto.Set("sha3_256hex", func(call goja.FunctionCall) goja.Value {
		sum := sha3.Sum256([]byte(toString(call.Argument(0))))
		return vm.ToValue(hex.EncodeToString(sum[:]))
	})
	_ = crypto.Set("base64encode", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(base64.StdEncoding.EncodeToString([]byte(toString(call.Argument(0)))))
	})
	_ = crypto.Set("base64decode", func(call goja.FunctionCall) goja.Value {
		decoded, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(string(decoded))
	})
	// aesCBCDecrypt：base64 密文 → UTF-8 明文（PKCS#7 去填充），供加密 API 源使用。
	_ = crypto.Set("aesCBCDecrypt", func(call goja.FunctionCall) goja.Value {
		encoded := toString(call.Argument(0))
		keyHex := toString(call.Argument(1))
		ivText := toString(call.Argument(2))
		ciphertext, err := base64.StdEncoding.DecodeString(strings.ReplaceAll(strings.TrimSpace(encoded), " ", "+"))
		if err != nil || len(ciphertext) == 0 || len(ciphertext)%aes.BlockSize != 0 {
			panic(vm.NewGoError(errors.New("密文格式无效")))
		}
		key, err := hex.DecodeString(keyHex)
		if err != nil || len(key) != 16 && len(key) != 24 && len(key) != 32 {
			panic(vm.NewGoError(errors.New("密钥格式无效")))
		}
		iv := []byte(ivText)
		if len(iv) != aes.BlockSize {
			panic(vm.NewGoError(errors.New("IV 长度无效")))
		}
		block, err := aes.NewCipher(key)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		plain := make([]byte, len(ciphertext))
		cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, ciphertext)
		if len(plain) == 0 || int(plain[len(plain)-1]) > aes.BlockSize {
			panic(vm.NewGoError(errors.New("密文填充无效")))
		}
		plain = plain[:len(plain)-int(plain[len(plain)-1])]
		return vm.ToValue(string(plain))
	})
	// aesCBCEncrypt：明文 + hex 密钥 + IV → base64 密文（PKCS#7 填充）。
	_ = crypto.Set("aesCBCEncrypt", func(call goja.FunctionCall) goja.Value {
		plain := []byte(toString(call.Argument(0)))
		key, err := hex.DecodeString(toString(call.Argument(1)))
		if err != nil || len(key) != 16 && len(key) != 24 && len(key) != 32 {
			panic(vm.NewGoError(errors.New("密钥格式无效")))
		}
		iv := []byte(toString(call.Argument(2)))
		if len(iv) != aes.BlockSize {
			panic(vm.NewGoError(errors.New("IV 长度无效")))
		}
		block, err := aes.NewCipher(key)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		pad := aes.BlockSize - len(plain)%aes.BlockSize
		padded := append(plain, bytes.Repeat([]byte{byte(pad)}, pad)...)
		out := make([]byte, len(padded))
		cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
		return vm.ToValue(base64.StdEncoding.EncodeToString(out))
	})
	// randomBytes：返回 n 字节随机数的 base64（IV/请求 ID 等）。
	_ = crypto.Set("randomBytes", func(call goja.FunctionCall) goja.Value {
		count := int(call.Argument(0).ToInteger())
		if count <= 0 || count > 256 {
			count = 16
		}
		buf := make([]byte, count)
		if _, err := rand.Read(buf); err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(buf))
	})
	// hmacSha256：raw 密钥（UTF-8）+ 数据 → hex 摘要。
	_ = crypto.Set("hmacSha256raw", func(call goja.FunctionCall) goja.Value {
		mac := hmac.New(sha256.New, []byte(toString(call.Argument(1))))
		mac.Write([]byte(toString(call.Argument(0))))
		return vm.ToValue(hex.EncodeToString(mac.Sum(nil)))
	})
	// gzip：UTF-8 文本 → base64 压缩数据。
	_ = crypto.Set("gzip", func(call goja.FunctionCall) goja.Value {
		var buffer bytes.Buffer
		writer := gzip.NewWriter(&buffer)
		if _, err := writer.Write([]byte(toString(call.Argument(0)))); err != nil {
			panic(vm.NewGoError(err))
		}
		if err := writer.Close(); err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(buffer.Bytes()))
	})
	_ = crypto.Set("hmacSha256hex", func(call goja.FunctionCall) goja.Value {
		mac := hmac.New(sha256.New, []byte(toString(call.Argument(1))))
		mac.Write([]byte(toString(call.Argument(0))))
		return vm.ToValue(hex.EncodeToString(mac.Sum(nil)))
	})
	_ = crypto.Set("hexdecode", func(call goja.FunctionCall) goja.Value {
		decoded, err := hex.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(string(decoded))
	})
	// —— 二进制安全接口（黄豆/旧版黄果等自定义协议需要）——
	// 约定：binary 参数与返回值都是 base64 文本，保证字节不被 UTF-8 破坏。

	// base64decodeBytes / base64encodeBytes 是 base64decode/encode 的显式别名，
	// 语义相同，单独命名以免调用方误以为有字节数组类型。
	_ = crypto.Set("hexdecodeBytes", func(call goja.FunctionCall) goja.Value {
		decoded, err := hex.DecodeString(strings.TrimSpace(toString(call.Argument(0))))
		if err != nil {
			panic(vm.NewGoError(errors.New("hex 编码无效")))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(decoded))
	})
	_ = crypto.Set("hexencodeBytes", func(call goja.FunctionCall) goja.Value {
		decoded, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("base64 编码无效")))
		}
		return vm.ToValue(hex.EncodeToString(decoded))
	})
	// aesCBCEncryptBytes：明文(base64) + hex 密钥 + IV(base64) → 密文(base64)。
	// 与 aesCBCEncrypt 的区别是不经字符串直通，密文可安全拼接 IV 前缀。
	_ = crypto.Set("aesCBCEncryptBytes", func(call goja.FunctionCall) goja.Value {
		plain, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("明文编码无效")))
		}
		key, err := hex.DecodeString(toString(call.Argument(1)))
		if err != nil || len(key) != 16 && len(key) != 24 && len(key) != 32 {
			panic(vm.NewGoError(errors.New("密钥格式无效")))
		}
		iv, err := base64.StdEncoding.DecodeString(toString(call.Argument(2)))
		if err != nil || len(iv) != aes.BlockSize {
			panic(vm.NewGoError(errors.New("IV 长度无效")))
		}
		out, err := aesCBCEncryptBytes(plain, key, iv)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(out))
	})
	// aesCBCDecryptBytes：密文(base64) + hex 密钥 + IV(base64) → 明文(base64)。
	_ = crypto.Set("aesCBCDecryptBytes", func(call goja.FunctionCall) goja.Value {
		cipherText, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil || len(cipherText) == 0 {
			panic(vm.NewGoError(errors.New("密文格式无效")))
		}
		key, err := hex.DecodeString(toString(call.Argument(1)))
		if err != nil || len(key) != 16 && len(key) != 24 && len(key) != 32 {
			panic(vm.NewGoError(errors.New("密钥格式无效")))
		}
		iv, err := base64.StdEncoding.DecodeString(toString(call.Argument(2)))
		if err != nil || len(iv) != aes.BlockSize {
			panic(vm.NewGoError(errors.New("IV 长度无效")))
		}
		out, err := aesCBCDecryptBytes(cipherText, key, iv)
		if err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(out))
	})
	// hmacSha256KeyBytes：密钥(base64) + 数据(base64) → 原始摘要(base64)。
	// 黄豆的请求密钥是 HMAC-SHA256 原始 32 字节，不能经 hex 文本传递。
	_ = crypto.Set("hmacSha256KeyBytes", func(call goja.FunctionCall) goja.Value {
		key, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("密钥编码无效")))
		}
		data, err := base64.StdEncoding.DecodeString(toString(call.Argument(1)))
		if err != nil {
			panic(vm.NewGoError(errors.New("数据编码无效")))
		}
		mac := hmac.New(sha256.New, key)
		mac.Write(data)
		return vm.ToValue(base64.StdEncoding.EncodeToString(mac.Sum(nil)))
	})
	// gzipBytes：原始字节(base64) → gzip 压缩后(base64)。
	_ = crypto.Set("gzipBytes", func(call goja.FunctionCall) goja.Value {
		plain, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("数据编码无效")))
		}
		var buffer bytes.Buffer
		writer := gzip.NewWriter(&buffer)
		if _, err := writer.Write(plain); err != nil {
			panic(vm.NewGoError(err))
		}
		if err := writer.Close(); err != nil {
			panic(vm.NewGoError(err))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(buffer.Bytes()))
	})
	// gunzipBytes：gzip 数据(base64) → 原始字节(base64)。
	_ = crypto.Set("gunzipBytes", func(call goja.FunctionCall) goja.Value {
		compressed, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("数据编码无效")))
		}
		reader, err := gzip.NewReader(bytes.NewReader(compressed))
		if err != nil {
			panic(vm.NewGoError(errors.New("gzip 数据无效")))
		}
		plain, readErr := io.ReadAll(io.LimitReader(reader, 20<<20))
		_ = reader.Close()
		if readErr != nil {
			panic(vm.NewGoError(readErr))
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(plain))
	})
	// sha256Bytes：原始字节(base64) → hex 摘要。
	_ = crypto.Set("sha256Bytes", func(call goja.FunctionCall) goja.Value {
		data, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("数据编码无效")))
		}
		sum := sha256.Sum256(data)
		return vm.ToValue(hex.EncodeToString(sum[:]))
	})
	// concatBytes：拼接多段 base64 数据，返回 base64（IV+密文 组包用）。
	_ = crypto.Set("concatBytes", func(call goja.FunctionCall) goja.Value {
		var joined []byte
		for _, argument := range call.Arguments {
			part, err := base64.StdEncoding.DecodeString(toString(argument))
			if err != nil {
				panic(vm.NewGoError(errors.New("数据编码无效")))
			}
			joined = append(joined, part...)
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(joined))
	})
	// sliceBytes：按字节区间切分 base64 数据，返回 base64。
	_ = crypto.Set("sliceBytes", func(call goja.FunctionCall) goja.Value {
		data, err := base64.StdEncoding.DecodeString(toString(call.Argument(0)))
		if err != nil {
			panic(vm.NewGoError(errors.New("数据编码无效")))
		}
		start := int(call.Argument(1).ToInteger())
		end := int(call.Argument(2).ToInteger())
		if start < 0 || start > len(data) {
			start = 0
		}
		if end <= 0 || end > len(data) {
			end = len(data)
		}
		if end < start {
			end = start
		}
		return vm.ToValue(base64.StdEncoding.EncodeToString(data[start:end]))
	})
	return crypto
}

// aesCBCEncryptBytes 是 PKCS#7 填充的 AES-CBC 加密，纯字节接口。
func aesCBCEncryptBytes(plain, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	pad := block.BlockSize() - len(plain)%block.BlockSize()
	padded := append(append([]byte{}, plain...), bytes.Repeat([]byte{byte(pad)}, pad)...)
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return out, nil
}

// aesCBCDecryptBytes 是 PKCS#7 去填充的 AES-CBC 解密，纯字节接口。
func aesCBCDecryptBytes(cipherText, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(cipherText)%block.BlockSize() != 0 {
		return nil, errors.New("密文长度不是块大小的整数倍")
	}
	plain := make([]byte, len(cipherText))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, cipherText)
	if len(plain) == 0 {
		return nil, errors.New("密文为空")
	}
	pad := int(plain[len(plain)-1])
	if pad == 0 || pad > block.BlockSize() || pad > len(plain) {
		return nil, errors.New("密文填充无效")
	}
	for _, value := range plain[len(plain)-pad:] {
		if int(value) != pad {
			return nil, errors.New("密文填充无效")
		}
	}
	return plain[:len(plain)-pad], nil
}

// buildRequest 把 hg.fetch 的 (url, options) 归一为宿主请求。
// options 为 nil 或未提供时按 GET 处理。
func buildRequest(url string, raw any) (Request, error) {
	request := Request{Method: "GET", URL: url}
	if raw == nil {
		return request, nil
	}
	options, ok := raw.(map[string]any)
	if !ok {
		return Request{}, errors.New("hg.fetch 选项必须是对象")
	}
	if method, ok := options["method"].(string); ok && method != "" {
		request.Method = strings.ToUpper(method)
	}
	if body, ok := options["body"].(string); ok {
		request.Body = body
	}
	// bodyBase64 用于二进制请求体（如黄豆的 IV+密文）。
	if encoded, ok := options["bodyBase64"].(string); ok && encoded != "" {
		request.BodyBase64 = encoded
		request.Body = ""
	}
	if headers, ok := options["headers"].(map[string]any); ok {
		request.Headers = map[string]string{}
		for key, value := range headers {
			if text, ok := value.(string); ok {
				request.Headers[key] = text
			}
		}
	}
	return request, nil
}

// fetchValue 把宿主响应转成 JS 可见对象。
// bodyBase64 始终存在：二进制协议（黄豆解密）必须读它，文本源继续用 body。
func fetchValue(vm *goja.Runtime, response *Response) map[string]any {
	return map[string]any{
		"status":     response.Status,
		"headers":    response.Headers,
		"body":       response.Body,
		"bodyBase64": response.BodyBase64,
	}
}

// consoleText 拼接 hg.log 的可变参数。
func consoleText(args []goja.Value) string {
	parts := make([]string, 0, len(args))
	for _, arg := range args {
		parts = append(parts, toString(arg))
	}
	return strings.Join(parts, " ")
}

func toString(value goja.Value) string {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return ""
	}
	return value.String()
}

// nativeAnyText 从已 Export 的 JS 值取字符串（fetchAll 的嵌套选项）。
func nativeAnyText(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case fmt.Stringer:
		return typed.String()
	default:
		return fmt.Sprintf("%v", typed)
	}
}

var _ = cascadia.Compile // 占位引用：htmlObject 在 htmlapi.go 中使用
