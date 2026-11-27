package cliche

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "gt:testkit"

// Save as over a file the person chose keeps its mode, and a link to it stays a link (fsx.DOCUMENT).
@(test)
save_as_keeps_the_file_it_writes_over :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	defer delete(dir)
	target := strings.concatenate({dir, "/shot.png"}, context.temp_allocator)
	link := strings.concatenate({dir, "/link.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(target, transmute([]u8)string("old")) == nil)
	testing.expect_value(t, posix.chmod(strings.clone_to_cstring(target, context.temp_allocator), {.IRUSR, .IWUSR, .IRGRP}), posix.result.OK)
	testing.expect_value(t, posix.symlink(strings.clone_to_cstring(target, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator)), posix.result.OK)

	rgba := make([]u8, 2 * 2 * 4)
	job := Job_Save_As{shot = {rgba = rgba, size = {2, 2}, scale = 1}, path = strings.clone(link), format = .Png_Fast}
	saved := save_as_shot(&job)
	defer delete(saved.path)
	testing.expect_value(t, saved.error, Flow_Error.None)

	st: posix.stat_t
	testing.expect_value(t, posix.lstat(strings.clone_to_cstring(link, context.temp_allocator), &st), posix.result.OK)
	testing.expect(t, posix.S_ISLNK(st.st_mode), "the link was replaced by a file")
	testing.expect_value(t, posix.stat(strings.clone_to_cstring(target, context.temp_allocator), &st), posix.result.OK)
	testing.expect_value(t, transmute(posix.mode_t)(transmute(u32)st.st_mode & 0o777), posix.mode_t{.IRUSR, .IWUSR, .IRGRP})
	testing.expect(t, st.st_size > 3, "the target was not written")
}
