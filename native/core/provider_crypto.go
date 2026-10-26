package core

// 站源共用的密码学与编码工具。
// 站源实现本身已迁到 JS 扩展，但红果（Go 内置）与野果的客户端仍依赖
// AES-CBC、PKCS#7、随机标识等基础能力，集中放在这里避免散落。

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
)

// pkcs7Pad 按块大小补填充字节。
func pkcs7Pad(src []byte, blockSize int) []byte {
	pad := blockSize - len(src)%blockSize
	return append(src, bytes.Repeat([]byte{byte(pad)}, pad)...)
}

// pkcs7Unpad 校验并去掉 PKCS#7 填充。
func pkcs7Unpad(src []byte, blockSize int) ([]byte, error) {
	if len(src) == 0 || len(src)%blockSize != 0 {
		return nil, errors.New("invalid pkcs7 length")
	}
	pad := int(src[len(src)-1])
	if pad == 0 || pad > blockSize || pad > len(src) {
		return nil, errors.New("invalid pkcs7 padding")
	}
	for _, value := range src[len(src)-pad:] {
		if int(value) != pad {
			return nil, errors.New("invalid pkcs7 padding bytes")
		}
	}
	return src[:len(src)-pad], nil
}

// aesCBCEncrypt 是 PKCS#7 填充的 AES-CBC 加密。
func aesCBCEncrypt(plain, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(plain, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return out, nil
}

// aesCBCDecrypt 是 PKCS#7 去填充的 AES-CBC 解密。
func aesCBCDecrypt(cipherText, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(cipherText)%block.BlockSize() != 0 {
		return nil, errors.New("ciphertext is not block aligned")
	}
	out := make([]byte, len(cipherText))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, cipherText)
	return pkcs7Unpad(out, block.BlockSize())
}

// atoiDefault 解析整数，失败时返回回退值。
func atoiDefault(s string, fallback int) int {
	if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		return n
	}
	return fallback
}

// randomHex 返回 n 字节随机数据的 hex 表示。
func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}

// uuidLike 返回 8-4-4-4-12 形态的随机标识（站点要求的请求编号格式）。
func uuidLike() string {
	raw := randomHex(16)
	if len(raw) != 32 {
		return raw
	}
	return raw[:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:]
}
