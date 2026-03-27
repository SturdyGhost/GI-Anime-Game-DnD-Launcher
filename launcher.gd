extends Node2D

@onready var http = $HTTPRequest
@onready var file_downloader = $FileDownloader
@onready var play_button = $Control/HBoxContainer/PlayButton
@onready var Progress = $Control/HBoxContainer/VBoxContainer/ProgressBar

const GITHUB_API_URL = "https://api.github.com/repos/SturdyGhost/GI-Anime-Game-DnD-Client/releases/latest"
const EXE_NAME = "Genshin DnD Client.exe"

var INSTALL_PATH = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/Genshin_DnD_Client/"
var exe_path: String
var download_url: String
var remote_digest: String
var progress_target = 0

func _ready():
	print("Launcher started.")
	exe_path = INSTALL_PATH + EXE_NAME
	Progress.value = 0
	Progress.max_value = 100
	Progress.visible = true
	play_button.disabled = true

	ensure_install_folder_exists()
	fetch_latest_release()

func ensure_install_folder_exists():
	if not DirAccess.dir_exists_absolute(INSTALL_PATH):
		var err = DirAccess.make_dir_recursive_absolute(INSTALL_PATH)
		if err != OK:
			print("Failed to create install folder.")
		else:
			print("Created install folder at: ", INSTALL_PATH)
	advance_progress()

func local_file_sha256() -> String:
	if not FileAccess.file_exists(exe_path):
		return ""
	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var file = FileAccess.open(exe_path, FileAccess.READ)
	if not file:
		return ""
	while file.get_position() < file.get_length():
		var chunk = file.get_buffer(1048576)  # 1 MB chunks
		ctx.update(chunk)
	file.close()
	var hash_bytes = ctx.finish()
	return hash_bytes.hex_encode()

func fetch_latest_release():
	print("Checking GitHub for latest release...")
	http.request(GITHUB_API_URL, ["Accept: application/vnd.github+json"])
	advance_progress()

func _on_http_request_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		print("Failed to fetch release info: ", response_code)
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json or not json.has("assets") or json["assets"].size() == 0:
		print("No assets found in latest release.")
		return

	var asset = json["assets"][0]
	download_url = asset.get("browser_download_url", "")
	var tag = json.get("tag_name", "unknown")
	# Digest format from GitHub: "sha256:abcdef..."
	var raw_digest = asset.get("digest", "")
	if raw_digest.begins_with("sha256:"):
		remote_digest = raw_digest.substr(7)
	else:
		remote_digest = raw_digest

	print("Latest release: ", tag)
	print("Remote SHA256:  ", remote_digest)
	advance_progress()

	var local_hash = local_file_sha256()
	print("Local SHA256:   ", local_hash if local_hash != "" else "(no local file)")
	advance_progress()

	if local_hash != "" and local_hash == remote_digest:
		print("Game is up-to-date.")
		play_button.disabled = false
		var tween = create_tween()
		tween.tween_property(Progress, "value", Progress.max_value, 0.1)
		fade_out_progress_bar()
	else:
		if local_hash == "":
			print("No local file — downloading.")
		else:
			print("Hash mismatch — updating.")
		download_game_client()

func download_game_client():
	if download_url == "":
		print("No download URL available.")
		return
	print("Downloading from: ", download_url)
	file_downloader.request(download_url)
	advance_progress()

func _on_file_downloader_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	# GitHub redirects release assets — follow 302s
	if response_code == 302 or response_code == 301:
		for header in headers:
			if header.to_lower().begins_with("location:"):
				var redirect_url = header.substr(header.find(":") + 1).strip_edges()
				print("Following redirect...")
				file_downloader.request(redirect_url)
				return
		print("Redirect with no Location header.")
		return

	if response_code != 200:
		print("Download failed: ", response_code)
		play_button.disabled = false
		return

	advance_progress()

	# Permanently delete old exe if it exists
	if FileAccess.file_exists(exe_path):
		var err = DirAccess.remove_absolute(exe_path)
		if err != OK:
			print("Warning: failed to delete old exe (error ", err, ")")
		else:
			print("Deleted old exe.")

	# Write the new file
	var file = FileAccess.open(exe_path, FileAccess.WRITE)
	if file:
		file.store_buffer(body)
		file.close()
		print("Saved new client to: ", exe_path)
	else:
		print("Failed to write client exe.")

	play_button.disabled = false
	var tween = create_tween()
	tween.tween_property(Progress, "value", Progress.max_value, 0.1)
	fade_out_progress_bar()

func advance_progress():
	var step_fill = randi_range(10, 25)
	progress_target += step_fill
	progress_target = min(progress_target, 99)
	var tween = create_tween()
	tween.tween_property(Progress, "value", progress_target, 0.1)

func fade_out_progress_bar():
	var tween = create_tween()
	tween.tween_interval(0.5)
	tween.tween_property(Progress, "modulate:a", 0.0, 0.8)
	tween.tween_callback(func(): Progress.visible = false)

func _on_play_button_pressed() -> void:
	print("Trying to launch game from: ", exe_path)
	if not FileAccess.file_exists(exe_path):
		print("EXE file not found at: ", exe_path)
		return
	var success = OS.create_process(exe_path, [])
	if success:
		print("Game launched successfully. Closing launcher.")
		await get_tree().create_timer(2.0).timeout
		get_tree().quit()
	else:
		print("Failed to launch game.")
