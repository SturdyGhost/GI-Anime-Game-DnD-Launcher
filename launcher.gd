extends Node2D

@onready var http = $HTTPRequest
@onready var file_downloader = $FileDownloader
@onready var play_button = $Control/HBoxContainer/PlayButton
@onready var progress_bar = $Control/HBoxContainer/VBoxContainer/ProgressBar
@onready var status_label = $Control/HBoxContainer/VBoxContainer/StatusLabel

const GITHUB_API_URL = "https://api.github.com/repos/SturdyGhost/GI-Anime-Game-DnD-Client/releases/latest"
const EXE_NAME = "Genshin DnD Client.exe"

# Progress phases — each phase owns a slice of the bar
const PHASE_CHECK = 0.0       # 0-10%: fetching release info
const PHASE_VERIFY = 10.0     # 10-20%: hashing local file
const PHASE_DOWNLOAD = 20.0   # 20-95%: downloading
const PHASE_DONE = 100.0

var INSTALL_PATH = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/Genshin_DnD_Client/"
var exe_path: String
var download_url: String
var remote_digest: String

# Hashing state — spread across frames so UI doesn't freeze
var hash_ctx: HashingContext
var hash_file: FileAccess
var hash_file_length: int = 0
var is_hashing: bool = false

func _ready():
	exe_path = INSTALL_PATH + EXE_NAME
	progress_bar.value = 0
	progress_bar.max_value = 100
	progress_bar.visible = true
	play_button.disabled = true

	ensure_install_folder_exists()
	set_status("Checking for updates...")
	fetch_latest_release()

func _process(_delta):
	if is_hashing:
		process_hash_chunk()
	if file_downloader.get_body_size() > 0:
		update_download_progress()

func set_status(text: String):
	status_label.text = text

func set_progress(value: float):
	progress_bar.value = value

func ensure_install_folder_exists():
	if not DirAccess.dir_exists_absolute(INSTALL_PATH):
		var err = DirAccess.make_dir_recursive_absolute(INSTALL_PATH)
		if err != OK:
			print("Failed to create install folder.")
		else:
			print("Created install folder at: ", INSTALL_PATH)

func fetch_latest_release():
	set_progress(PHASE_CHECK)
	http.request(GITHUB_API_URL, ["Accept: application/vnd.github+json"])

func _on_http_request_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		set_status("Connection failed — check your internet")
		print("HTTP request failed with result: ", result)
		return
	if response_code != 200:
		set_status("Failed to check for updates (HTTP %d)" % response_code)
		print("Failed to fetch release info: ", response_code)
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json or not json.has("assets") or json["assets"].size() == 0:
		set_status("No release found")
		return

	var asset = json["assets"][0]
	download_url = asset.get("browser_download_url", "")
	var tag = json.get("tag_name", "unknown")
	var raw_digest = asset.get("digest", "")
	if raw_digest.begins_with("sha256:"):
		remote_digest = raw_digest.substr(7)
	else:
		remote_digest = raw_digest

	print("Latest release: ", tag)
	set_progress(PHASE_VERIFY)

	if not FileAccess.file_exists(exe_path):
		set_status("No game found — downloading v%s..." % tag)
		set_progress(PHASE_DOWNLOAD)
		download_game_client()
	else:
		set_status("Verifying local files...")
		start_async_hash()

# --- Async hashing (spread across frames) ---

func start_async_hash():
	hash_ctx = HashingContext.new()
	hash_ctx.start(HashingContext.HASH_SHA256)
	hash_file = FileAccess.open(exe_path, FileAccess.READ)
	if not hash_file:
		on_hash_complete("")
		return
	hash_file_length = hash_file.get_length()
	is_hashing = true

func process_hash_chunk():
	if not hash_file or hash_file.get_position() >= hash_file_length:
		finish_hash()
		return

	# Process several MB per frame to keep it fast but not freeze
	var bytes_per_frame = 4 * 1048576  # 4 MB
	var bytes_read = 0
	while bytes_read < bytes_per_frame and hash_file.get_position() < hash_file_length:
		var chunk = hash_file.get_buffer(1048576)
		hash_ctx.update(chunk)
		bytes_read += chunk.size()

	# Update progress within the verify phase (10-20%)
	var ratio = float(hash_file.get_position()) / float(hash_file_length)
	set_progress(PHASE_VERIFY + ratio * (PHASE_DOWNLOAD - PHASE_VERIFY))

	var pct = int(ratio * 100)
	set_status("Verifying local files... %d%%" % pct)

func finish_hash():
	is_hashing = false
	hash_file.close()
	var hash_bytes = hash_ctx.finish()
	var local_hash = hash_bytes.hex_encode()
	hash_file = null
	hash_ctx = null
	on_hash_complete(local_hash)

func on_hash_complete(local_hash: String):
	print("Local SHA256:  ", local_hash if local_hash != "" else "(none)")
	print("Remote SHA256: ", remote_digest)

	if local_hash != "" and local_hash == remote_digest:
		set_status("Game is up to date!")
		set_progress(PHASE_DONE)
		play_button.disabled = false
		fade_out_progress_bar()
	else:
		set_status("Update available — downloading...")
		set_progress(PHASE_DOWNLOAD)
		download_game_client()

# --- Download ---

func download_game_client():
	if download_url == "":
		set_status("Error: no download URL")
		return
	file_downloader.request(download_url)

func update_download_progress():
	var total = file_downloader.get_body_size()
	var downloaded = file_downloader.get_downloaded_bytes()
	if total <= 0:
		return
	var ratio = float(downloaded) / float(total)
	# Map to the download phase (20-95%)
	set_progress(PHASE_DOWNLOAD + ratio * (95.0 - PHASE_DOWNLOAD))

	var mb_done = downloaded / 1048576.0
	var mb_total = total / 1048576.0
	set_status("Downloading... %.0f / %.0f MB" % [mb_done, mb_total])

func _on_file_downloader_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		set_status("Download failed — check your internet")
		print("Download request failed with result: ", result)
		play_button.disabled = false
		return

	# GitHub redirects release assets — follow 302s
	if response_code == 302 or response_code == 301:
		for header in headers:
			if header.to_lower().begins_with("location:"):
				var redirect_url = header.substr(header.find(":") + 1).strip_edges()
				print("Following redirect...")
				file_downloader.request(redirect_url)
				return
		set_status("Download error: redirect failed")
		return

	if response_code != 200:
		set_status("Download failed (error %d)" % response_code)
		play_button.disabled = false
		return

	set_status("Installing...")
	set_progress(96.0)

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
		set_status("Update complete!")
	else:
		set_status("Error: failed to save file")
		print("Failed to write client exe.")

	set_progress(PHASE_DONE)
	play_button.disabled = false
	fade_out_progress_bar()

func fade_out_progress_bar():
	var tween = create_tween()
	tween.tween_interval(1.5)
	tween.tween_property(progress_bar, "modulate:a", 0.0, 0.8)
	tween.tween_property(status_label, "modulate:a", 0.0, 0.8)
	tween.tween_callback(func():
		progress_bar.visible = false
		status_label.visible = false
	)

func _on_play_button_pressed() -> void:
	if not FileAccess.file_exists(exe_path):
		set_status("Game not found — restart launcher")
		return
	var success = OS.create_process(exe_path, [])
	if success:
		set_status("Launching...")
		await get_tree().create_timer(2.0).timeout
		get_tree().quit()
	else:
		set_status("Failed to launch game")
