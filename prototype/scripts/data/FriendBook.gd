extends RefCounted

# Local-only friend roster. Static state, no autoload, no project.godot change.
const BOOK_PATH := "user://friend_book.cfg"

static var entries: Array[Dictionary] = []

static func _demo_entries() -> Array[Dictionary]:
	return [
		{"id": "demo_1001", "name": "星澜", "note": "本地演示好友"},
		{"id": "demo_1002", "name": "绯月", "note": "本地演示好友"}
	]

static func load_book() -> void:
	entries.clear()
	var cfg := ConfigFile.new()
	if cfg.load(BOOK_PATH) != OK:
		entries = _demo_entries()
		save_book()
		return
	for key in cfg.get_sections():
		entries.append({
			"id": str(key),
			"name": str(cfg.get_value(key, "name", str(key))),
			"note": str(cfg.get_value(key, "note", ""))
		})

static func save_book() -> void:
	var cfg := ConfigFile.new()
	for entry in entries:
		var id := str(entry.get("id", ""))
		if id.is_empty():
			continue
		cfg.set_value(id, "name", str(entry.get("name", "")))
		cfg.set_value(id, "note", str(entry.get("note", "")))
	cfg.save(BOOK_PATH)

static func has(id: String) -> bool:
	for entry in entries:
		if str(entry.get("id", "")) == id:
			return true
	return false

static func add(id: String, name: String, note: String = "") -> bool:
	if id.is_empty() or has(id):
		return false
	entries.append({"id": id, "name": name, "note": note})
	return true

static func remove(id: String) -> bool:
	for i in range(entries.size()):
		if str(entries[i].get("id", "")) == id:
			entries.remove_at(i)
			return true
	return false

static func find_by_name(q: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var needle := q.to_lower()
	if needle.is_empty():
		return result
	for entry in entries:
		var name := str(entry.get("name", "")).to_lower()
		var id := str(entry.get("id", "")).to_lower()
		if name.contains(needle) or id.contains(needle):
			result.append(entry)
	return result

static func all() -> Array[Dictionary]:
	return entries
