package atri

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/url"
	"sort"
	"strings"
)

const secretAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

func randomSecret() (string, error) {
	var b strings.Builder
	limit := big.NewInt(int64(len(secretAlphabet)))
	for i := 0; i < 32; i++ {
		n, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", err
		}
		b.WriteByte(secretAlphabet[n.Int64()])
	}
	return b.String(), nil
}

func cipherKeyAndIV(secret string) ([]byte, []byte, error) {
	if len(secret) < aes.BlockSize {
		return nil, nil, fmt.Errorf("secret is too short")
	}
	key := []byte(secret[:aes.BlockSize])
	sum := sha256.Sum256([]byte(secret))
	iv := []byte(hex.EncodeToString(sum[:])[:aes.BlockSize])
	return key, iv, nil
}

func encryptParams(params map[string]any, secret string) (string, error) {
	body, err := json.Marshal(params)
	if err != nil {
		return "", err
	}
	key, iv, err := cipherKeyAndIV(secret)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	padded := pkcs7Pad(body, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return base64.StdEncoding.EncodeToString(out), nil
}

func decryptPayload(encoded, secret string) ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	key, iv, err := cipherKeyAndIV(secret)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(data)%block.BlockSize() != 0 {
		return nil, fmt.Errorf("invalid ciphertext length")
	}
	out := make([]byte, len(data))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, data)
	return pkcs7Unpad(out, block.BlockSize())
}

func signature(params map[string]any, secret string) string {
	keys := make([]string, 0, len(params))
	for key, value := range params {
		if key == "sign" || value == nil {
			continue
		}
		if text, ok := value.(string); ok && text == "" {
			continue
		}
		switch value.(type) {
		case map[string]any, []any:
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, jsEncodeComponent(key)+"="+jsEncodeComponent(fmt.Sprint(params[key])))
	}
	joined := strings.Join(parts, "&") + "&key=" + secret
	decoded, err := url.PathUnescape(joined)
	if err != nil {
		decoded = joined
	}
	sum := md5.Sum([]byte(decoded))
	return hex.EncodeToString(sum[:])
}

func jsEncodeComponent(value string) string {
	const hexChars = "0123456789ABCDEF"
	var b strings.Builder
	for _, ch := range []byte(value) {
		if (ch >= 'A' && ch <= 'Z') ||
			(ch >= 'a' && ch <= 'z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '-' || ch == '_' || ch == '.' || ch == '!' ||
			ch == '~' || ch == '*' || ch == '\'' || ch == '(' || ch == ')' {
			b.WriteByte(ch)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hexChars[ch>>4])
		b.WriteByte(hexChars[ch&0x0f])
	}
	return b.String()
}

func pkcs7Pad(data []byte, blockSize int) []byte {
	padding := blockSize - len(data)%blockSize
	return append(data, bytes.Repeat([]byte{byte(padding)}, padding)...)
}

func pkcs7Unpad(data []byte, blockSize int) ([]byte, error) {
	if len(data) == 0 || len(data)%blockSize != 0 {
		return nil, fmt.Errorf("invalid padded data")
	}
	padding := int(data[len(data)-1])
	if padding == 0 || padding > blockSize || padding > len(data) {
		return nil, fmt.Errorf("invalid padding")
	}
	for _, b := range data[len(data)-padding:] {
		if int(b) != padding {
			return nil, fmt.Errorf("invalid padding")
		}
	}
	return data[:len(data)-padding], nil
}
