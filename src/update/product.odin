// What cliche is to the toolkit's update package (gt:update, its docs/update.md): its name in the manifests and the
// release's file names, what its signatures cover, and the public half of its update key (clichetool update keygen; the
// private half is in the release workflow's secret UPDATE_SIGNING_KEY). The program checks with it (updates.odin),
// clichetool signs with it (clichetool package).
package cliche_update

import update "gt:update"

// The public half of cliche's update key: what `clichetool update keygen <file>` printed (base64url, 43 characters).
UPDATE_PUBLIC_KEY :: "B7n6qXsLD5glvtTW75Lx4vQw4F4rZ3hbr4xnE6qBGA8"

PRODUCT :: update.Product{
	name         = "cliche",
	sign_context = "cliche-update-v1\n",
	public_key   = UPDATE_PUBLIC_KEY,
}
