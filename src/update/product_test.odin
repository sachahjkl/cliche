package cliche_update

import "core:testing"
import signing "gt:signing"

// (an empty or broken key: no update could be checked, and every copy out would stay where it is)
@(test)
the_update_key_is_a_key :: proc(t: ^testing.T) {
	_, ok := signing.key_decode(PRODUCT.public_key)
	testing.expect(t, ok, "32 bytes of base64url")
}
