extends Node2D

@onready var http = $HTTPRequest
@onready var file_downloader = $FileDownloader
@onready var play_button = $Control/HBoxContainer/PlayButton
@onready var retry_button = $Control/HBoxContainer/RetryButton
@onready var progress_bar = $Control/HBoxContainer/VBoxContainer/ProgressBar
@onready var status_label = $Control/HBoxContainer/VBoxContainer/StatusLabel

const GITHUB_API_URL = "https://api.github.com/repos/SturdyGhost/GI-Anime-Game-DnD-Client/releases/latest"
const EXE_NAME = "Genshin DnD Client.exe"
const AUTO_LAUNCH_DELAY = 2.0  # seconds before auto-launching when up to date

# Progress phases — each phase owns a slice of the bar
const PHASE_CHECK = 0.0       # 0-10%: fetching release info
const PHASE_VERIFY = 10.0     # 10-20%: hashing local file
const PHASE_DOWNLOAD = 20.0   # 20-95%: downloading
const PHASE_DONE = 100.0

var INSTALL_PATH = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS) + "/Genshin_DnD_Client/"
var exe_path: String
var etag_path: String
var download_url: String
var remote_digest: String
var saved_etag: String = ""

# Hashing state — spread across frames so UI doesn't freeze
var hash_ctx: HashingContext
var hash_file: FileAccess
var hash_file_length: int = 0
var is_hashing: bool = false

func _ready():
	exe_path = INSTALL_PATH + EXE_NAME
	etag_path = INSTALL_PATH + "etag.txt"
	progress_bar.value = 0
	progress_bar.max_value = 100
	progress_bar.visible = true
	play_button.disabled = true
	retry_button.visible = false

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

func show_error(message: String):
	set_status(message)
	retry_button.visible = true
	play_button.disabled = true

func ensure_install_folder_exists():
	if not DirAccess.dir_exists_absolute(INSTALL_PATH):
		var err = DirAccess.make_dir_recursive_absolute(INSTALL_PATH)
		if err != OK:
			print("Failed to create install folder.")
		else:
			print("Created install folder at: ", INSTALL_PATH)

func load_etag() -> String:
	if FileAccess.file_exists(etag_path):
		var f = FileAccess.open(etag_path, FileAccess.READ)
		if f:
			var tag = f.get_as_text().strip_edges()
			f.close()
			return tag
	return ""

func save_etag(etag: String):
	var f = FileAccess.open(etag_path, FileAccess.WRITE)
	if f:
		f.store_string(etag)
		f.close()

func fetch_latest_release():
	set_progress(PHASE_CHECK)
	saved_etag = load_etag()
	var request_headers = ["Accept: application/vnd.github+json"]
	if saved_etag != "":
		request_headers.append("If-None-Match: %s" % saved_etag)
	http.request(GITHUB_API_URL, request_headers)

func _on_http_request_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		show_error("Connection failed — check your internet")
		print("HTTP request failed with result: ", result)
		return

	# 304 = nothing changed since last check, doesn't count against rate limit
	if response_code == 304:
		print("GitHub returned 304 — no new release since last check.")
		if FileAccess.file_exists(exe_path):
			game_ready()
		else:
			set_status("Game files missing — re-downloading...")
			save_etag("")
			http.request(GITHUB_API_URL, ["Accept: application/vnd.github+json"])
		return

	if response_code != 200:
		if response_code == 403:
			show_error("Rate limited by GitHub — try again later")
		else:
			show_error("Failed to check for updates (HTTP %d)" % response_code)
		print("Failed to fetch release info: ", response_code)
		return

	# Save the ETag so future checks can use conditional requests
	for header in headers:
		if header.to_lower().begins_with("etag:"):
			save_etag(header.substr(header.find(":") + 1).strip_edges())
			break

	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json or not json.has("assets") or json["assets"].size() == 0:
		show_error("No release found")
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

	var bytes_per_frame = 4 * 1048576  # 4 MB
	var bytes_read = 0
	while bytes_read < bytes_per_frame and hash_file.get_position() < hash_file_length:
		var chunk = hash_file.get_buffer(1048576)
		hash_ctx.update(chunk)
		bytes_read += chunk.size()

	var ratio = float(hash_file.get_position()) / float(hash_file_length)
	set_progress(PHASE_VERIFY + ratio * (PHASE_DOWNLOAD - PHASE_VERIFY))
	set_status("Verifying local files... %d%%" % int(ratio * 100))

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
		game_ready()
	else:
		set_status("Update available — downloading...")
		set_progress(PHASE_DOWNLOAD)
		download_game_client()

# --- Up to date — auto-launch ---

func game_ready():
	set_status("Game is up to date!")
	set_progress(PHASE_DONE)
	play_button.disabled = false
	fade_out_progress_bar()
	auto_launch()

func auto_launch():
	if not FileAccess.file_exists(exe_path):
		return
	# Countdown so the user can see it's about to launch
	for i in range(int(AUTO_LAUNCH_DELAY), 0, -1):
		set_status("Launching in %d..." % i)
		await get_tree().create_timer(1.0).timeout
	launch_game()

# --- Download ---

func download_game_client():
	if download_url == "":
		show_error("Error: no download URL")
		return
	file_downloader.request(download_url)

func update_download_progress():
	var total = file_downloader.get_body_size()
	var downloaded = file_downloader.get_downloaded_bytes()
	if total <= 0:
		return
	var ratio = float(downloaded) / float(total)
	set_progress(PHASE_DOWNLOAD + ratio * (95.0 - PHASE_DOWNLOAD))
	var mb_done = downloaded / 1048576.0
	var mb_total = total / 1048576.0
	set_status("Downloading... %.0f / %.0f MB" % [mb_done, mb_total])

func _on_file_downloader_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		show_error("Download failed — check your internet")
		print("Download request failed with result: ", result)
		return

	# GitHub redirects release assets — follow 302s
	if response_code == 302 or response_code == 301:
		for header in headers:
			if header.to_lower().begins_with("location:"):
				var redirect_url = header.substr(header.find(":") + 1).strip_edges()
				print("Following redirect...")
				file_downloader.request(redirect_url)
				return
		show_error("Download error: redirect failed")
		return

	if response_code != 200:
		show_error("Download failed (error %d)" % response_code)
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
		show_error("Error: failed to save file")
		print("Failed to write client exe.")
		return

	set_progress(PHASE_DONE)
	play_button.disabled = false
	fade_out_progress_bar()
	auto_launch()

# --- UI ---

func fade_out_progress_bar():
	var tween = create_tween()
	tween.tween_interval(0.5)
	tween.tween_property(progress_bar, "modulate:a", 0.0, 0.8)
	tween.tween_property(status_label, "modulate:a", 0.0, 0.8)
	tween.tween_callback(func():
		progress_bar.visible = false
	)

func launch_game():
	if not FileAccess.file_exists(exe_path):
		set_status("Game not found — restart launcher")
		return
	var success = OS.create_process(exe_path, [])
	if success:
		set_status("Launching...")
		await get_tree().create_timer(1.0).timeout
		get_tree().quit()
	else:
		set_status("Failed to launch game")

func _on_play_button_pressed() -> void:
	launch_game()

func _on_retry_button_pressed() -> void:
	retry_button.visible = false
	progress_bar.value = 0
	progress_bar.modulate.a = 1.0
	progress_bar.visible = true
	status_label.modulate.a = 1.0
	status_label.visible = true
	set_status("Retrying...")
	fetch_latest_release()
