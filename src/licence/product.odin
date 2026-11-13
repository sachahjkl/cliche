// What cliche's licence is to the toolkit's licence package (gt:licence, docs/licence.md): its name in the payload, its
// key's tag, what its signatures cover, its file and its editions. The program checks with it (licence.odin), clichetool
// signs and checks with it (`clichetool licence`), and the licence Worker has the same values (its products/cliche.jsonc).
package cliche_licence

import licence "gt:licence"

PRODUCT :: licence.Product{
	name           = "cliche",
	title          = "cliche",
	version_tag    = "CLICHE1",
	sign_context   = "cliche-licence-v1\n",
	file_extension = ".clichelicence",
	// (`clichetool licence keygen` makes the pair; empty until then: no licence of the real key is accepted)
	public_key     = "",
	// (the development pair: its seed is public on purpose, clichetool's dev_seed)
	dev_public_key = "4u0W0RNCU5S16f_LtlKwtM4uokN4fZ6m8jIgT26ynyo",
	editions       = {0 = {id = "supporter", title = "Supporter"}},
}
