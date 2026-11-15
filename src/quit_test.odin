package cliche

import "base:runtime"
import "core:testing"
import instance "gt:instance"

// An installer's `cliche --quit` reaches the instance's handler as instance.MESSAGE_QUIT: the interface's next turn ends
// the loop as the Quit action does. A ping (`--status`) only proves that cliche answers: it changes nothing.
@(test)
the_messages_of_an_installer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := new(App)
	defer free(app)
	defer delete(app.inbox)

	app_message(app, transmute([]u8)string(instance.MESSAGE_PING))
	app_inbox(app)
	testing.expect(t, !app.quit, "a ping does not end cliche")

	app_message(app, transmute([]u8)string(instance.MESSAGE_QUIT))
	testing.expect(t, !app.quit, "the handler's thread does not touch the interface's state")
	app_inbox(app)
	testing.expect(t, app.quit, "a quit ends cliche as its Quit does")

	c, ok := command_parse(command_format({verb = .Quit}))
	testing.expect(t, ok && c.verb == .Quit, "cliche's own quit is the shared message")
	testing.expect_value(t, command_format({verb = .Ping}), instance.MESSAGE_PING)
}
