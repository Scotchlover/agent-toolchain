# Safe — compile-safe access to autoload singletons.
# Global class_name scripts are compiled even in `godot -s` headless contexts
# where autoloads are NOT registered; bare `GS.` / `TEL.` identifiers fail to
# compile there and break the whole test dependency graph. Route every
# cross-autoload access through these dynamic lookups instead.
class_name Safe

static func gs() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("GS")
	return null


static func tel() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("TEL")
	return null


static func main() -> Node:
	var g := gs()
	if g != null and "main" in g:
		var m = g.get("main")
		if m != null and is_instance_valid(m):
			return m
	return null
