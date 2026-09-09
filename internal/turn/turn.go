// Package turn issues time-limited TURN credentials compatible with coturn's
// use-auth-secret mode.
package turn

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"time"
)

// Credentials returns a username of the form "<expiry>:<accountID>" and the
// matching HMAC-SHA1 credential.
func Credentials(secret, accountID string, ttl time.Duration, now time.Time) (username, credential string) {
	username = fmt.Sprintf("%d:%s", now.Add(ttl).Unix(), accountID)
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(username))
	credential = base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return username, credential
}
