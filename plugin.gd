tool
extends EditorPlugin

# --- Behavior knobs ---
const HANDLE_PX := 7.0          # handle hit radius in screen pixels
const EDGE_PX := 6.0            # edge hit thickness in screen pixels
const MIN_SIZE := 1.0           # minimum width/height in local units
const DRAW_HANDLES := true
const RETICLE_PX := 15.0
const KNOCKBACK_DRAG_MULT := 7.0

const COLOR_DEFAULT := Color(0.2, 0.9, 1.0, 0.9)
const COLOR_SHIFT := Color.orange
const COLOR_CTRL := Color.greenyellow
const COLOR_BOTH := Color.slategray

const LABEL_COLOR := Color.black
const LABEL_OUTLINE := Color.whitesmoke
const LABEL_OUTLINE_ALPHA := 0.55
const LABEL_HOVER := 0.8
const LABEL_HOVER_OUTLINE_ALPHA := 0.8
const LABEL_DEFAULT := 0.6
const LABEL_DRAG := 0.0

enum DragMode {
	NONE,
	MOVE, MOVE_RAY, MOVE_KNOCKBACK,
	RESIZE_L, RESIZE_R, RESIZE_T, RESIZE_B,
	RESIZE_TL, RESIZE_TR, RESIZE_BL, RESIZE_BR
}

var _selection: EditorSelection
var _active: Node = null
var _prev_selection_valid = false

var _drag_mode = DragMode.NONE
var _dragging := false
var _shift_held := false
var _ctrl_held := false
var _alt_held := false

var _start_x := 0
var _start_y := 0
var _start_w := 0
var _start_h := 0
var _start_to_x := 0
var _start_to_y := 0
var _start_kb_p := 0.0
var _start_kb_x := 0.0
var _start_kb_y := 0.0

var _temp_start_x := 0
var _temp_start_y := 0
var _temp_start_w := 0
var _temp_start_h := 0

var _start_mouse_local := Vector2.ZERO

var _label_alpha := LABEL_DEFAULT
var _outline_alpha := LABEL_OUTLINE_ALPHA
var _font : DynamicFont

func _enter_tree() -> void:
	_selection = get_editor_interface().get_selection()
	if _selection and not _selection.is_connected("selection_changed", self, "_on_selection_changed"):
		_selection.connect("selection_changed", self, "_on_selection_changed")
	get_editor_interface().get_inspector().connect("property_edited", self, "_on_property_changed")
	
	_font = DynamicFont.new()
	_font.font_data = load("res://ui/PixeloidSans.ttf")
	_font.size = 20
	_font.outline_size = 2
#	_font.extra_spacing_char = 1
	
	set_force_draw_over_forwarding_enabled()
	_on_selection_changed()

func _exit_tree() -> void:
	_label_alpha = 0.0
	_outline_alpha = 0.0
	_font = null
	update_overlays()
	
	if _selection and _selection.is_connected("selection_changed", self, "_on_selection_changed"):
		_selection.disconnect("selection_changed", self, "_on_selection_changed")
	get_editor_interface().get_inspector().disconnect("property_edited", self, "_on_property_changed")
		
func handles(object: Object) -> bool:
	return _is_collision_box(object)
		
func _refresh_selection() -> void:
	_prev_selection_valid = _is_collision_box(_active)
	_active = _get_single_selected_node()

func _on_selection_changed() -> void:
	
	call_deferred("_refresh_selection")
	
	_dragging = false
	_shift_held = false
	_ctrl_held = false
	_alt_held = false
	_drag_mode = DragMode.NONE
	
	call_deferred("_refresh_overlay")

func _on_property_changed(property):
	_shift_held = false
	_ctrl_held = false
	_alt_held = false
	update_overlays()

func _refresh_overlay():
	if not _prev_selection_valid:
		yield(get_tree().create_timer(0.2), "timeout")
	update_overlays()
	
func forward_canvas_gui_input(event: InputEvent) -> bool:
	if not _is_collision_box(_active):
		return false
	
#	if _update_time > 0:
#		_update_time -= get_physics_process_delta_time()
	
	if event is InputEventKey:
		if event.scancode == KEY_SHIFT:
			_shift_held = event.pressed
		if event.scancode == KEY_CONTROL:
			_ctrl_held = event.pressed
		if event.scancode == KEY_ALT:
			_alt_held = event.pressed
			
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			return _begin_drag(event.position)
		else:
			if _dragging:
				_end_drag()
				return true
			return false
			
	if event is InputEventMouseMotion:
			
		if _dragging:
#			_label_alpha = LABEL_DRAG
			_update_drag(event.position)
			update_overlays()
			return true
			
		else:
			var xform := _get_canvas_xform(_active)
			if xform:
				var rect_screen := _get_rect_screen(_active, xform)
				if _pick_drag_mode(event.position, rect_screen) in [DragMode.MOVE, DragMode.MOVE_RAY, DragMode.MOVE_KNOCKBACK]:
					_label_alpha = LABEL_HOVER
					_outline_alpha = LABEL_HOVER_OUTLINE_ALPHA
				else: 
					_label_alpha = LABEL_DEFAULT
					_outline_alpha = LABEL_OUTLINE_ALPHA
			
			if _is_collision_box(_active):
				if _active.position != Vector2.ZERO: 
					_active.position = Vector2.ZERO
				if _active.scale != Vector2.ONE: 
					_active.scale = Vector2.ONE
				if _active.rotation != 0: 
					_active.rotation = 0
					
			update_overlays()
			return false

	return false

func forward_canvas_draw_over_viewport(overlay: Control) -> void:
	if not _is_collision_box(_active):
		return

	var xform := _get_canvas_xform(_active)
	if xform == null:
		return

	var rect_screen := _get_rect_screen(_active, xform)
	
	overlay.draw_rect(rect_screen, _get_color(), false, 2.0)
	
	if _is_swepthitbox(_active):
		var center_screen := rect_screen.get_center()
		var swept_screen := _get_swept_point_screen(_active, xform)
		
		if (center_screen - swept_screen).length() > HANDLE_PX:
			overlay.draw_line(center_screen, swept_screen, _get_color(), 2.0)
		overlay.draw_circle(swept_screen, HANDLE_PX + 2.0, _get_color())
		overlay.draw_circle(swept_screen, HANDLE_PX - 2.0, Color(0.05, 0.05, 0.05, 0.9))
	
	if ("dir_x" in _active) and ("dir_y" in _active) and ("knockback" in _active):
		var center_screen := rect_screen.get_center()
		var kb_screen := _get_knockback_point_screen(_active, xform)
		
		var square_outline = Rect2(kb_screen, Vector2.ZERO).grow(HANDLE_PX + 1.5)
		var square_inside = Rect2(kb_screen, Vector2.ZERO).grow(HANDLE_PX - 2.0)
		if (center_screen - kb_screen).length() > HANDLE_PX:
			overlay.draw_line(center_screen, kb_screen, _get_color(), 2.0)
		overlay.draw_rect(square_outline, _get_color())
		overlay.draw_rect(square_inside, Color(0.05, 0.05, 0.05, 0.9))
		
	var position_01:Vector2
	var position_02:Vector2
	for coord in ["x", "y"]:
		position_01 = rect_screen.get_center()
		position_02 = rect_screen.get_center()
		
		position_01[coord] += RETICLE_PX
		position_02[coord] -= RETICLE_PX
		
		overlay.draw_line(position_01, position_02, _get_color(), 2.0)
		
	if DRAW_HANDLES:
		for p in _get_handle_points_screen(rect_screen):
			overlay.draw_circle(p, HANDLE_PX, _get_color())
			overlay.draw_circle(p, HANDLE_PX - 2.0, Color(0.05, 0.05, 0.05, 0.9))
	
	_draw_data_label(overlay, rect_screen)
	
func _draw_data_label(overlay: Control, rect_screen: Rect2) -> void:
	if not is_instance_valid(_font):
		return
	var font := _font
	
	if _label_alpha <= 0.0:
		return
		
	var frame_data := _get_frame_data(_active)
	if frame_data == "":
		return

	var lines := frame_data.split("\n")
	var line_height := font.get_height()+15
	
	var pos := rect_screen.position
	pos.y -= float(line_height * lines.size()) * 0.5
	pos.y += 6
	pos.x += 0

	var text_color := LABEL_COLOR
	text_color.a = _label_alpha

	var outline_color := LABEL_OUTLINE
	outline_color.a = _label_alpha
	font.outline_color = outline_color*_outline_alpha

	for i in range(lines.size()):
		var line_pos := pos + Vector2(0, i * (font.size))
		overlay.draw_string(font, line_pos, lines[i], text_color)

func _get_canvas_xform(n: Node2D) -> Transform2D:
	return n.get_viewport_transform()

func _get_rect_local(n: Node) -> Rect2:
	var cx := float(n.get("x"))
	var cy := float(n.get("y"))
	var w := float(n.get("width"))
	var h := float(n.get("height"))
	return Rect2(Vector2(cx - w, cy - h), Vector2(w*2, h*2))

func _local_to_screen(n: Node, canvas_xform: Transform2D, local_p: Vector2) -> Vector2:
	var global_p := (n as Node2D).to_global(local_p)
	return canvas_xform.xform(global_p)

func _screen_to_local(n: Node, canvas_xform: Transform2D, screen_p: Vector2) -> Vector2:
	var global_p = canvas_xform.affine_inverse().xform(screen_p)
	return (n as Node2D).to_local(global_p)

func _get_rect_screen(n: Node, canvas_xform: Transform2D) -> Rect2:
	var r := _get_rect_local(n)

	# Convert 4 corners to screen; build a screen-space AABB (safe for scale; assumes no rotation as requested).
	var p0 := _local_to_screen(n, canvas_xform, r.position)
	var p1 := _local_to_screen(n, canvas_xform, r.position + Vector2(r.size.x, 0))
	var p2 := _local_to_screen(n, canvas_xform, r.position + Vector2(0, r.size.y))
	var p3 := _local_to_screen(n, canvas_xform, r.position + r.size)

	var minx := min(min(p0.x, p1.x), min(p2.x, p3.x))
	var maxx := max(max(p0.x, p1.x), max(p2.x, p3.x))
	var miny := min(min(p0.y, p1.y), min(p2.y, p3.y))
	var maxy := max(max(p0.y, p1.y), max(p2.y, p3.y))

	return Rect2(Vector2(minx, miny), Vector2(maxx - minx, maxy - miny))

func _get_handle_points_screen(rs: Rect2) -> Array:
	var tl := rs.position
	var tr := rs.position + Vector2(rs.size.x, 0)
	var bl := rs.position + Vector2(0, rs.size.y)
	var br := rs.position + rs.size
	var tm := rs.position + Vector2(rs.size.x * 0.5, 0)
	var bm := rs.position + Vector2(rs.size.x * 0.5, rs.size.y)
	var lm := rs.position + Vector2(0, rs.size.y * 0.5)
	var rm := rs.position + Vector2(rs.size.x, rs.size.y * 0.5)
	return [tl, tm, tr, rm, br, bm, bl, lm]

func _begin_drag(mouse_screen: Vector2) -> bool:
	
	var xform := _get_canvas_xform(_active)
	if xform == null:
		return false

	var rect_screen := _get_rect_screen(_active, xform)
	var mode := _pick_drag_mode(mouse_screen, rect_screen)
	if mode == DragMode.NONE:
		return false

	_drag_mode = mode
	_dragging = true

	_start_x = int(_active.get("x"))
	_start_y = int(_active.get("y"))
	_start_w = int(_active.get("width"))
	_start_h = int(_active.get("height"))

	_temp_start_x = _start_x
	_temp_start_y = _start_y
	_temp_start_w = _start_w
	_temp_start_h = _start_h
	
	if _is_swepthitbox(_active):
		_start_to_x = int(_active.get("to_x"))
		_start_to_y = int(_active.get("to_y"))
	
	if ("dir_x" in _active) and ("dir_y" in _active) and ("knockback" in _active):
		_start_kb_p = float(_active.get("knockback"))
		_start_kb_x = float(_active.get("dir_x"))
		_start_kb_y = float(_active.get("dir_y"))
		
	_start_mouse_local = _screen_to_local(_active, xform, mouse_screen)

	return true

func _update_drag(mouse_screen: Vector2) -> void:
	var xform := _get_canvas_xform(_active)
	if xform == null:
		return

#	if _update_time > 0:
#		return
#	_update_time = 0.02

	var mouse_local := _screen_to_local(_active, xform, mouse_screen)
	var delta := mouse_local - _start_mouse_local

	var new_x := _temp_start_x
	var new_y := _temp_start_y
	var new_w := _temp_start_w
	var new_h := _temp_start_h

	var shift_mod_for :float= 1.0 if _shift_held else 0.5
	var shift_mod_against :float= 0.0 if _shift_held else 0.5
	var ctrl_mod_delta_y :float= -delta.x if _ctrl_held else delta.y
	var ctrl_mod_delta_yi :float= delta.x if _ctrl_held else delta.y
	
	match _drag_mode:
		DragMode.MOVE:
			new_x += delta.x
			new_y += delta.y

		DragMode.RESIZE_R:
			new_w += int(delta.x * shift_mod_for)
			new_x += int(delta.x * shift_mod_against)
			if _ctrl_held:
				new_h = new_w
				
		DragMode.RESIZE_L:
			new_w -= int(delta.x * shift_mod_for)
			new_x += int(delta.x * shift_mod_against)
			if _ctrl_held:
				new_h = new_w
				
		DragMode.RESIZE_B:
			new_h += int(delta.y * shift_mod_for)
			new_y += int(delta.y * shift_mod_against)
			if _ctrl_held:
				new_w = new_h
				
		DragMode.RESIZE_T:
			new_h -= int(delta.y * shift_mod_for)
			new_y += int(delta.y * shift_mod_against)
			if _ctrl_held:
				new_w = new_h
				
		DragMode.RESIZE_TR:
			new_w += int(delta.x * shift_mod_for)
			new_h -= int(delta.y * shift_mod_for)
			new_x += int(delta.x * shift_mod_against)
			new_y += int(ctrl_mod_delta_y * shift_mod_against)
			if _ctrl_held:
				new_h = new_w
				
		DragMode.RESIZE_TL:
			new_w -= int(delta.x * shift_mod_for)
			new_h -= int(delta.y * shift_mod_for)
			new_x += int(delta.x * shift_mod_against)
			new_y += int(ctrl_mod_delta_yi * shift_mod_against)
			if _ctrl_held:
				new_h = new_w
				
		DragMode.RESIZE_BR:
			new_w += int(delta.x * shift_mod_for)
			new_h += int(delta.y * shift_mod_for)
			new_x += int(delta.x * shift_mod_against)
			new_y += int(ctrl_mod_delta_yi * shift_mod_against)
			if _ctrl_held:
				new_h = new_w
				
		DragMode.RESIZE_BL:
			new_w -= int(delta.x * shift_mod_for)
			new_h += int(delta.y * shift_mod_for)
			new_x += int(delta.x * shift_mod_against)
			new_y += int(ctrl_mod_delta_y * shift_mod_against)
			if _ctrl_held:
				new_h = new_w
				
		DragMode.MOVE_RAY:
			var center := Vector2(int(_active.get("x")), int(_active.get("y")))
			var new_to := mouse_local - center

			_set_int_if_changed(_active, "to_x", new_to.x)
			_set_int_if_changed(_active, "to_y", new_to.y)
			return
			
		DragMode.MOVE_KNOCKBACK:
			var center := Vector2(int(_active.get("x")), int(_active.get("y"))) + _get_knockback_dirs(_active, false)
			var new_to := (mouse_local - center) / (KNOCKBACK_DRAG_MULT*0.9)
			
			var normalized := new_to.normalized()
			if new_to.length() == 0:
				normalized = Vector2.ZERO
			
			var step 				= 0.05
			if _alt_held: step 		= 0.01
			normalized = normalized.snapped( Vector2(step, step))
			if not _ctrl_held:
				_active.set("dir_x", str( normalized.x ).pad_decimals(1))
				_active.set("dir_y", str( normalized.y ).pad_decimals(1))
			
			var knockback_step 				= 1
			if _alt_held: knockback_step 	= 0.25
			if not _shift_held:
				_active.set("knockback", str(stepify(new_to.length(), knockback_step)).pad_decimals(1) )
			return

		_:
			pass

	if new_w < MIN_SIZE:
		new_w = abs(new_w)
		
		_temp_start_x = new_x
		_temp_start_w = new_w
		_temp_start_y = new_y
		_temp_start_h = new_h
		_drag_mode = _mirror_drag_mode_x(_drag_mode, mouse_screen)
		
	if new_h < MIN_SIZE:
		new_h = abs(new_h)
		
		_temp_start_x = new_x
		_temp_start_w = new_w
		_temp_start_y = new_y
		_temp_start_h = new_h
		_drag_mode = _mirror_drag_mode_y(_drag_mode, mouse_screen)
		
		
	_set_int_if_changed(_active, "x", new_x)
	_set_int_if_changed(_active, "y", new_y)
	_set_int_if_changed(_active, "width", new_w)
	_set_int_if_changed(_active, "height", new_h)

func _mirror_drag_mode_x(mode: int, mouse_screen:Vector2) -> int:
	var xform := _get_canvas_xform(_active)
	if xform == null:
		return mode
	
	_start_mouse_local = _screen_to_local(_active, xform, mouse_screen)
	match mode:
		DragMode.RESIZE_L: return DragMode.RESIZE_R
		DragMode.RESIZE_R: return DragMode.RESIZE_L
		DragMode.RESIZE_TL: return DragMode.RESIZE_TR
		DragMode.RESIZE_TR: return DragMode.RESIZE_TL
		DragMode.RESIZE_BL: return DragMode.RESIZE_BR
		DragMode.RESIZE_BR: return DragMode.RESIZE_BL
		_: return mode
	
func _mirror_drag_mode_y(mode: int, mouse_screen:Vector2) -> int:
	var xform := _get_canvas_xform(_active)
	if xform == null:
		return mode
		
	_start_mouse_local = _screen_to_local(_active, xform, mouse_screen)
	match mode:
		DragMode.RESIZE_T: return DragMode.RESIZE_B
		DragMode.RESIZE_B: return DragMode.RESIZE_T
		DragMode.RESIZE_TL: return DragMode.RESIZE_BL
		DragMode.RESIZE_BL: return DragMode.RESIZE_TL
		DragMode.RESIZE_TR: return DragMode.RESIZE_BR
		DragMode.RESIZE_BR: return DragMode.RESIZE_TR
		_: return mode
			
func _end_drag() -> void:
	_dragging = false
	
	var end_x := int(_active.get("x"))
	var end_y := int(_active.get("y"))
	var end_w := int(_active.get("width"))
	var end_h := int(_active.get("height"))
	
	var is_swept := _is_swepthitbox(_active)
	var end_to_x := 0
	var end_to_y := 0
	if is_swept:
		end_to_x = int(_active.get("to_x"))
		end_to_y = int(_active.get("to_y"))
	
	var has_knockback = ("dir_x" in _active) and ("dir_y" in _active) and ("knockback" in _active)
	var end_kb_x := "0.0"
	var end_kb_y := "0.0"
	var end_kb_p := "0.0"
	if has_knockback:
		end_kb_p = str(_active.get("knockback"))
		end_kb_x = str(_active.get("dir_x"))
		end_kb_y = str(_active.get("dir_y"))
		
	var ur := get_undo_redo()
	ur.create_action("Edit CollisionBox (drag)")
	ur.add_do_property(_active, "x", end_x)
	ur.add_do_property(_active, "y", end_y)
	ur.add_do_property(_active, "width", end_w)
	ur.add_do_property(_active, "height", end_h)
	if is_swept:
		ur.add_do_property(_active, "to_x", end_to_x)
		ur.add_do_property(_active, "to_y", end_to_y)
	if has_knockback:
		ur.add_do_property(_active, "dir_x", end_kb_x)
		ur.add_do_property(_active, "dir_y", end_kb_y)
		ur.add_do_property(_active, "knockback", end_kb_p)
	ur.add_do_method(_active, "property_list_changed_notify")
	
	ur.add_undo_property(_active, "x", _start_x)
	ur.add_undo_property(_active, "y", _start_y)
	ur.add_undo_property(_active, "width", _start_w)
	ur.add_undo_property(_active, "height", _start_h)
	if is_swept:
		ur.add_undo_property(_active, "to_x", _start_to_x)
		ur.add_undo_property(_active, "to_y", _start_to_y)
	if has_knockback:
		ur.add_undo_property(_active, "dir_x", _start_kb_x)
		ur.add_undo_property(_active, "dir_y", _start_kb_y)
		ur.add_undo_property(_active, "knockback", _start_kb_p)
	ur.add_undo_method(_active, "property_list_changed_notify")
	ur.commit_action()
	
	_drag_mode = DragMode.NONE
	update_overlays()

func _pick_drag_mode(mouse: Vector2, rs: Rect2) -> int:
	var tl := rs.position
	var tr := rs.position + Vector2(rs.size.x, 0)
	var bl := rs.position + Vector2(0, rs.size.y)
	var br := rs.position + rs.size
	var tm := rs.position + Vector2(rs.size.x * 0.5, 0)
	var bm := rs.position + Vector2(rs.size.x * 0.5, rs.size.y)
	var lm := rs.position + Vector2(0, rs.size.y * 0.5)
	var rm := rs.position + Vector2(rs.size.x, rs.size.y * 0.5)
	
	if mouse.distance_to(tl) <= HANDLE_PX: return DragMode.RESIZE_TL
	if mouse.distance_to(tr) <= HANDLE_PX: return DragMode.RESIZE_TR
	if mouse.distance_to(bl) <= HANDLE_PX: return DragMode.RESIZE_BL
	if mouse.distance_to(br) <= HANDLE_PX: return DragMode.RESIZE_BR
	if mouse.distance_to(tm) <= HANDLE_PX: return DragMode.RESIZE_T
	if mouse.distance_to(bm) <= HANDLE_PX: return DragMode.RESIZE_B
	if mouse.distance_to(lm) <= HANDLE_PX: return DragMode.RESIZE_L
	if mouse.distance_to(rm) <= HANDLE_PX: return DragMode.RESIZE_R
	
	if _is_swepthitbox(_active):
		var xform := _get_canvas_xform(_active)
		var swept_point := _get_swept_point_screen(_active, xform)

		if mouse.distance_to(swept_point) <= HANDLE_PX + 4.0:
			return DragMode.MOVE_RAY
	
	if ("dir_x" in _active) and ("dir_y" in _active) and ("knockback" in _active):
		var xform := _get_canvas_xform(_active)
		var kb_point := _get_knockback_point_screen(_active, xform)

		if mouse.distance_to(kb_point) <= HANDLE_PX + 4.0:
			return DragMode.MOVE_KNOCKBACK

	var left_dist := abs(mouse.x - rs.position.x)
	var right_dist := abs(mouse.x - (rs.position.x + rs.size.x))
	var top_dist := abs(mouse.y - rs.position.y)
	var bot_dist := abs(mouse.y - (rs.position.y + rs.size.y))

	var inside_x := mouse.x >= rs.position.x and mouse.x <= rs.position.x + rs.size.x
	var inside_y := mouse.y >= rs.position.y and mouse.y <= rs.position.y + rs.size.y
	var inside := inside_x and inside_y

	if inside_y and left_dist <= EDGE_PX: return DragMode.RESIZE_L
	if inside_y and right_dist <= EDGE_PX: return DragMode.RESIZE_R
	if inside_x and top_dist <= EDGE_PX: return DragMode.RESIZE_T
	if inside_x and bot_dist <= EDGE_PX: return DragMode.RESIZE_B

	if inside:
		return DragMode.MOVE

	return DragMode.NONE

func _get_single_selected_node() -> Node:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.empty():
		return null
	return nodes[0]

func _get_swept_point_local(n: Node) -> Vector2:
	return Vector2(
		int(n.get("x")) + int(n.get("to_x")),
		int(n.get("y")) + int(n.get("to_y"))
	)
	
func _get_swept_point_screen(n: Node, canvas_xform: Transform2D) -> Vector2:
	return _local_to_screen(n, canvas_xform, _get_swept_point_local(n))

func _get_knockback_point_local(n: Node) -> Vector2:
	return (_get_knockback_dirs(_active, false) * KNOCKBACK_DRAG_MULT) + Vector2(int(n.get("x")), int(n.get("y")))

func _get_knockback_point_screen(n: Node, canvas_xform: Transform2D) -> Vector2:
	return _local_to_screen(n, canvas_xform, _get_knockback_point_local(n))

func _set_int_if_changed(node: Object, prop: String, value: int) -> void:
	if int(node.get(prop)) != value:
		node.set(prop, value)
	
func _is_collision_box(o: Object) -> bool:
	if o == null:
		return false
	if not (o is Node2D):
		return false

	var n := o as Node
	var has_fields := ("x" in n) and ("y" in n) and ("width" in n) and ("height" in n)

	if not has_fields:
		return false

	return true

func _is_swepthitbox(o: Object) -> bool:
	return o is SweptHitbox

func _get_knockback_dirs(o: Object, normalized=true) -> Vector2:
	if not _is_collision_box(o):
		return Vector2.ZERO
	var has_fields := ("dir_x" in o) and ("dir_y" in o) and ("knockback" in o)
	if not has_fields:
		return Vector2.ZERO
	
	var vector := Vector2(float(o.dir_x), float(o.dir_y))
	if vector.length() != 0:
		vector = vector.normalized()
		
	if normalized:
		return vector
	return vector * float(o.knockback)




























# VISUALS
func _get_color() -> Color:
	if _ctrl_held and _shift_held:
		return COLOR_BOTH
	if _ctrl_held:
		return COLOR_CTRL
	if _shift_held:
		return COLOR_SHIFT
	return COLOR_DEFAULT

func _get_frame_data(o: Object) -> String:
	if not _is_collision_box(o):
		return ""
	
	var n := o as Node2D
	var text := """"""

	if _dragging and _drag_mode == DragMode.MOVE_KNOCKBACK:
		var locked_text = " (X)"
		var t = "Knockback: "+str(n.knockback)	
		if not n.knockback.is_valid_float():	t = "\nKnockback: Invalid (Invalid Number)"
		if n.knockback.empty():					t = "\nKnockback: Invalid (Not Set)"
		
		text += t
		if _shift_held: text += locked_text
		
		text += "\nDirection X: "+str(n.dir_x)
		if _ctrl_held: text += locked_text
		text += "\nDirection Y: "+str(n.dir_y)
		if _ctrl_held: text += locked_text
		
	elif _shift_held:
		if _dragging:
			_label_alpha = LABEL_DRAG
		
		if (n.get("hits_otg") is bool) and (n.get("hits_vs_standing") is bool) and (n.get("hits_vs_grounded") is bool) and (n.get("hits_vs_aerial") is bool) and (n.get("hits_vs_dizzy") is bool):
			if (n.hits_otg or n.hits_vs_standing or n.hits_vs_grounded or n.hits_vs_aerial or n.hits_vs_dizzy):
				text += "\nHits VS: "
				if n.hits_otg: 			text += "OTG, "
				if n.hits_vs_standing: 	text += "STANDING, "
				if n.hits_vs_grounded: 	text += "GROUNDED, "
				if n.hits_vs_aerial: 	text += "AERIAL, "
				if n.hits_vs_dizzy: 	text += "DIZZY, "
				text = text.rstrip(", ")

		if (n.get("hit_height") is int):
			var display 					= "High"
			if n.hit_height == 1: display 	= "Mid"
			if n.hit_height == 2: display 	= "Low"
			text += "\nHit Height: "+display
		
		if n.get("di_modifier") is String:
			var t = "\nDI Mod: "+n.di_modifier
			if not n.di_modifier.is_valid_float():		t = "\nDI Mod: Invalid (Invalid Number)"
			if n.di_modifier.empty():					t = "\nDI Mod: Invalid (Not Set)"
			text += t
		if n.get("sdi_modifier") is String:
			var t = "\nSDI Mod: "+n.sdi_modifier
			if not n.sdi_modifier.is_valid_float():		t = "\nSDI Mod: Invalid (Invalid Number)"
			if n.sdi_modifier.empty():					t = "\nSDI Mod: Invalid (Not Set)"
			text += t
		
		if n.get("followup_state"): text += "\nFollowup State: "+n.followup_state
		
	else:
		if _dragging:
			_label_alpha = LABEL_DRAG
			
		var start_tick = 0
		var end_tick = 0
		var is_hitbox := (n is Hitbox) 
		if n.get("start_tick") is int:
			start_tick = n.start_tick
			if not is_hitbox:
				start_tick += 1
		if n.get("active_ticks") is int:
			end_tick = (start_tick + n.active_ticks) - 1
			if n.active_ticks < -1:
				end_tick = -999
		if n.get("endless") or n.get("always_on"):
			end_tick = -1
			
		if (n.get("activated") is bool) and (not n.activated): text += "(INACTIVE)"
			
		if start_tick > 0 and end_tick != -999:
			text += "\n"

			if end_tick == -1:
				text += "["+str(start_tick)+"f - INF]" 		
			elif (end_tick < start_tick) or end_tick < -1:
				text += str(start_tick)+"f"
			elif end_tick > 1 and start_tick != end_tick:
				text += "["+str(start_tick)+"f - "+str(end_tick)+"f]"
			else:
				text += str(start_tick)+"f"
			
			if n.get("looping"):
				text += " ("+str(n.loop_active_ticks)+"f : "+str(n.loop_inactive_ticks)+"f)"
		
		var damage = 0
		var min_damage = 0
		var damage_in_combo = -1
		if n.get("damage"): damage = n.damage
		if n.get("minimum_damage"): min_damage = n.minimum_damage
		if n.get("damage_in_combo"): damage_in_combo = n.damage_in_combo
		
		if damage > 0:
			text += "\nDamage: "+str(damage)
			if min_damage > 0: text += " (Min. Damage: "+str(min_damage)+")"
			if damage_in_combo > -1: text += " (In Combo: "+str(damage_in_combo)+")"
			
		if (n.get("damage_proration") is int): text += "\nPRT: "+str(n.damage_proration)
		
		if (n.get("knockback") is String): 
			var t = "\nKnockback: "+str(n.knockback)	
			if n.knockback.empty():					t = "\nKnockback: Invalid (Not Set)"
			if not n.knockback.is_valid_float():	t = "\nKnockback: Invalid (Invalid Number)"
			text += t
			text += " (x: "+str(n.dir_x)
			text += ", y: "+str(n.dir_y)+")"
			
		if (n.get("group") is int): text += "\nGroup: "+str(n.group)	
		
		if (n.get("cancellable")) is bool and (n.get("block_cancel_allowed")) is bool and (n.get("block_punishable")) is bool and (n.get("guard_break")) is bool and (n.get("parriable")) is bool:
			var t := []
			if n.cancellable:			t.append("HIT CANCEL")
			if n.block_cancel_allowed: 	t.append("BLK CANCEL")
			if n.block_punishable:		t.append("BLK PUNISH")
			var gb_prt = ""
			if n.get("guard_break_proration") is int:
				gb_prt = " (PRT: "+str( n.guard_break_proration )+")"
			if n.guard_break:			t.append("GUARDBREAK"+gb_prt)
			if not n.parriable: 		t.append("UNPARRIABLE")
			
			if not t.empty():
				text += "\n" + ", ".join(t)

		if (n.get("plus_frames")) is int: text += "\nBlock Frames: "+str(n.plus_frames)
	
		if n.get("grounded_hit_state") and n.get("aerial_hit_state"):
			var hit_state = "Hit State: "+n.grounded_hit_state+" ("+n.aerial_hit_state+")"
			text += "\n"+hit_state
		
	return text
