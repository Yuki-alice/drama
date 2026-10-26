package ext

import (
	"context"
	"errors"
	"fmt"
	"sync"
)

// Request 是宿主网络能力的入参。
// BodyBase64 与 Body 二选一：二进制请求体（如黄豆的 IV+密文）必须走
// BodyBase64，避免 UTF-8 转换破坏字节。
type Request struct {
	Method     string            `json:"method"`
	URL        string            `json:"url"`
	Headers    map[string]string `json:"headers,omitempty"`
	Body       string            `json:"body,omitempty"`
	BodyBase64 string            `json:"bodyBase64,omitempty"`
}

// Response 是宿主网络能力的出参。
// BodyBase64 始终携带原始响应字节的 base64 视图；Body 是同一字节的
// UTF-8 文本视图，二进制响应（密文）必须读 BodyBase64。
type Response struct {
	Status     int               `json:"status"`
	Headers    map[string]string `json:"headers,omitempty"`
	Body       string            `json:"body"`
	BodyBase64 string            `json:"bodyBase64,omitempty"`
}

// Host 是宿主注入扩展的能力面；core 侧用现有网络栈与数据目录实现。
type Host interface {
	Fetch(ctx context.Context, source string, request Request) (*Response, error)
	Log(source, message string)
	StorageLoad(source string) (map[string]string, error)
	StorageSave(source string, values map[string]string) error
}

// ErrScriptCancel 表示脚本执行被 context 取消中断。
var ErrScriptCancel = errors.New("扩展脚本执行已取消")

// Extension 是一个已加载的扩展源运行时。
// goja.Runtime 非并发安全：同源请求串行执行，取消通过 vm.Interrupt 注入；
// 中断后的 VM 状态不可靠，下一次调用前自动重建。
type Extension struct {
	manifest Manifest
	code     string
	registry *Registry
	runtime  Runtime
	mu       sync.Mutex
}

// Runtime 抽象 goja，便于测试替身与未来的脚本引擎替换。
type Runtime interface {
	RunProgram() error
	Call(name string, args []any) (value any, err error)
	Interrupt(reason error)
	// SetContext 注入本次调用的 context，让宿主能力（hg.fetch）随取消退出。
	SetContext(ctx context.Context)
}

// NewExtension 编译并加载扩展脚本，校验 source 契约对象存在。
func NewExtension(manifest Manifest, code string, registry *Registry) (*Extension, error) {
	if len(code) > MaxSourceBytes {
		return nil, errors.New("扩展脚本超过大小上限")
	}
	rt, err := registry.NewRuntime(manifest, code)
	if err != nil {
		return nil, fmt.Errorf("扩展脚本无法编译: %w", err)
	}
	if err := rt.RunProgram(); err != nil {
		return nil, fmt.Errorf("扩展脚本初始化失败: %w", err)
	}
	return &Extension{manifest: manifest, code: code, registry: registry, runtime: rt}, nil
}

// Manifest 返回扩展元数据。
func (e *Extension) Manifest() Manifest { return e.manifest }

// Call 执行 source.<method>；内部持锁串行，ctx 取消时中断脚本。
func (e *Extension) Call(ctx context.Context, method string, args []any) (any, error) {
	return e.call(ctx, method, args)
}

// call 在锁保护下执行脚本方法；ctx 取消时中断 VM 并等待执行协程退出。
func (e *Extension) call(ctx context.Context, method string, args []any) (any, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	type result struct {
		value any
		err   error
	}
	done := make(chan result, 1)
	e.runtime.SetContext(ctx)
	go func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				done <- result{err: fmt.Errorf("扩展脚本崩溃: %v", recovered)}
			}
		}()
		value, err := e.runtime.Call(method, args)
		done <- result{value: value, err: err}
	}()
	select {
	case outcome := <-done:
		return outcome.value, outcome.err
	case <-ctx.Done():
		e.runtime.Interrupt(ErrScriptCancel)
		outcome := <-done
		// 中断后的 VM 不可复用：丢弃并重建，保证后续请求不受影响。
		replacement, rebuildErr := NewExtension(e.manifest, e.code, e.registry)
		if rebuildErr == nil {
			e.runtime = replacement.runtime
		} else {
			e.runtime = brokenRuntime{rebuildErr}
		}
		if outcome.err != nil {
			return nil, outcome.err
		}
		return nil, ctx.Err()
	}
}

// brokenRuntime 在重建失败时兜底，让后续调用返回明确错误而不是 panic。
type brokenRuntime struct{ err error }

func (b brokenRuntime) RunProgram() error               { return b.err }
func (b brokenRuntime) Call(string, []any) (any, error) { return nil, b.err }
func (b brokenRuntime) Interrupt(error)                 {}
func (b brokenRuntime) SetContext(context.Context)      {}
