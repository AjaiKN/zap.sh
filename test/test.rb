#!/usr/bin/env ruby

require "minitest/autorun"
require "uri"

ENV["PATH"] = File.realpath(__dir__ + "/../bin") + ":" + ENV["PATH"]

def strategy strat
	ENV['ZAP_STRATEGY'] = strat
end

def xdg_data_home
	ret = ENV['XDG_DATA_HOME']
	if ret.nil? || ret.empty?
		"#{Dir.home}/.local/share"
	else
		ret
	end
end

def xdg_cache_home
	ret = ENV['XDG_CACHE_HOME']
	if ret.nil? || ret.empty?
		ret = "#{Dir.home}/.cache"
	else
		ret
	end
end

def percent_encode(path)
	path.split("/").map { URI::encode_uri_component(_1) }.join("/").gsub('*', '%2A').gsub('%7E', '~')
end

def test_chars
	ret = '!@#$%^&()_+-=[]{};,.`~'
	ret += '<>:"\\|?*' # characters not allowed in Windows filenames: https://stackoverflow.com/a/31976060
	ret += " \n\r\t"
	ret += (1..31).map(&:chr).join('') # control characters
	ret += '£€æü'
	ret += "\x7F"
	ret += '折り紙🕊é é﷽ᄀᄀᄀ각ᆨᆨ🇺🇸각नीநி﷽&ᄀᄀᄀ각ᆨᆨ🇺🇸각नीநி👩‍👩‍👦‍👦&👩‍👩‍👦‍👦&'
	# NOTE: Linux has a max file length (lower than the max for Mac)
	if RUBY_PLATFORM =~ /linux/
		ret = ret[0...100]
	end
	ret
end

TEST_CHARS = test_chars
# TEST_CHARS = ''

class TestZap < Minitest::Test
	## Replacement for Dir.mktmpdir where the temp dir is always part of the home directory.
	def mktmpdir_home(&block)
		dir = nil
		loop do
			dir = "#{xdg_cache_home}/my-test-tmp-dirs/#{rand(1000000000)}"
			break unless Dir.exist?(dir)
		end
		FileUtils.mkdir_p dir, mode: 0o700
		if block
			begin
				yield dir
			ensure
				FileUtils.remove_entry dir
			end
		else
			dir
		end
	end

	## Point XDG_DATA_HOME at a fresh temp dir for the duration of the block.
	def with_isolated_trash
		old = ENV['XDG_DATA_HOME']
		mktmpdir_home do |dir|
			ENV['XDG_DATA_HOME'] = dir
			yield "#{dir}/Trash"
		ensure
			ENV['XDG_DATA_HOME'] = old
		end
	end

	## Point HOME at a fresh temp dir (with an empty .Trash) for the duration of
	## the block, with XDG_DATA_HOME unset. Yields the temp HOME.
	def with_fake_home
		old_home, old_xdg = ENV['HOME'], ENV['XDG_DATA_HOME']
		mktmpdir_home do |home|
			FileUtils.mkdir "#{home}/.Trash"
			ENV['HOME'] = home
			ENV.delete 'XDG_DATA_HOME'
			yield home
		ensure
			ENV['HOME'], ENV['XDG_DATA_HOME'] = old_home, old_xdg
		end
	end

	## Mount a fresh tmpfs (a different filesystem from the home trash, with no
	## usable top-level trash directory) and yield a directory in it owned by the
	## current user. Skips the test if passwordless sudo isn't available.
	def with_tmpfs
		skip "running as root" if Process.uid == 0
		skip "needs passwordless sudo to mount a tmpfs" unless system "sudo", "-n", "true", out: File::NULL, err: File::NULL
		mktmpdir_home do |mnt|
			system "sudo", "-n", "mount", "-t", "tmpfs", "-o", "mode=755", "tmpfs", mnt, exception: true
			begin
				system "sudo", "-n", "install", "-d", "-o", Process.uid.to_s, "#{mnt}/w", exception: true
				yield "#{mnt}/w"
			ensure
				system "sudo", "-n", "chmod", "-R", "u+rwx", mnt
				system "sudo", "-n", "umount", mnt, exception: true
			end
		end
	end

	def zap_records(home)
		Dir.glob("#{home}/.local/share/zap/info/*.trashinfo")
	end

	def setup
		puts; puts
		@dir = mktmpdir_home
		FileUtils.cd @dir
		@filename = "#{Time.now.iso8601(10).gsub(':', '_')}__#{rand(1000000000)}__#{TEST_CHARS}.txt"
		@contents = Random.bytes(rand(1000))
		File.write @filename, @contents
	end

	def teardown
		FileUtils.rm_r @dir
	end

	def test_nonexistent_strategy_fails
		strategy "nonexistent_strategy"
		puts `zap -v -- '#{@filename}'`
		refute $?.success?
		assert File.exist? @filename
	end

	def test_freedesktop
		strategy "freedesktop"
		FileUtils.touch @filename
		puts `zap -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{xdg_data_home}/Trash/files/#{@filename}"
		assert_equal @contents, File.binread("#{xdg_data_home}/Trash/files/#{@filename}")

		assert File.exist? "#{xdg_data_home}/Trash/info/#{@filename}.trashinfo"
		trashinfo = File.read("#{xdg_data_home}/Trash/info/#{@filename}.trashinfo")
		assert_equal("[Trash Info]\n", trashinfo.lines[0])
		assert_equal("Path=#{percent_encode(FileUtils.pwd + "/" + @filename)}\n", trashinfo.lines[1])
		assert_match(/DeletionDate=\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\n/, trashinfo.lines[2])
		assert_equal(3, trashinfo.lines.length)
	end

	def test_trash_cli
		ENV["PATH"] += ":/opt/homebrew/opt/trash-cli/bin" # for Mac, since trash-cli is Keg-only
		skip "trash CLI not available" unless system "which trash-put"
		strategy "trash_cli"
		FileUtils.touch @filename
		puts `zap -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{xdg_data_home}/Trash/files/#{@filename}"
		assert_equal @contents, File.binread("#{xdg_data_home}/Trash/files/#{@filename}")

		assert File.exist? "#{xdg_data_home}/Trash/info/#{@filename}.trashinfo"
		trashinfo = File.read("#{xdg_data_home}/Trash/info/#{@filename}.trashinfo")
		assert_equal("[Trash Info]\n", trashinfo.lines[0])
		assert_equal("Path=#{percent_encode(FileUtils.pwd + "/" + @filename)}\n", trashinfo.lines[1])
		assert_match(/DeletionDate=\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\n/, trashinfo.lines[2])
		assert_equal(3, trashinfo.lines.length)
	end

	def test_gio
		skip "gio CLI not available" unless system "which gio"
		strategy "gio"
		FileUtils.touch @filename
		puts `zap -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{xdg_data_home}/Trash/files/#{@filename}"
		assert_equal @contents, File.binread("#{xdg_data_home}/Trash/files/#{@filename}")

		assert File.exist? "#{xdg_data_home}/Trash/info/#{@filename}.trashinfo"
		trashinfo = File.read("#{xdg_data_home}/Trash/info/#{@filename}.trashinfo")
		assert_equal("[Trash Info]\n", trashinfo.lines[0])
		assert_equal("Path=#{percent_encode(FileUtils.pwd + "/" + @filename)}\n", trashinfo.lines[1])
		assert_match(/DeletionDate=\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\d\n/, trashinfo.lines[2])
		assert_equal(3, trashinfo.lines.length)
	end

	def test_macos_trash_command
		skip "not on mac" unless `uname -s`.chomp == 'Darwin'
		strategy "macos_trash_command"
		FileUtils.touch @filename
		puts `zap -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{Dir.home}/.Trash/#{@filename}"
		assert_equal @contents, File.binread("#{Dir.home}/.Trash/#{@filename}")
	end

	def test_macos_applescript
		skip "not on mac" unless `uname -s`.chomp == 'Darwin'
		strategy "macos_applescript"
		FileUtils.touch @filename
		puts `zap -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{Dir.home}/.Trash/#{@filename}"
		# causes "operation not permitted" permissions error because of Mac's System
		# Integrity Protection - https://stackoverflow.com/q/58100326
		# assert_equal @contents, File.binread("#{Dir.home}/.Trash/#{@filename}")
	end

	def test_macos_mv
		skip "not on mac" unless `uname -s`.chomp == 'Darwin'
		strategy "macos_mv"
		FileUtils.touch @filename
		puts `zap -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{Dir.home}/.Trash/#{@filename}"
		assert_equal @contents, File.binread("#{Dir.home}/.Trash/#{@filename}")
	end

	def test_strategy_missing_argument_fails
		strategy "freedesktop"
		out = `zap -s 2>&1`
		assert_equal 2, $?.exitstatus
		assert_match(/requires an argument/, out)
	end

	def test_bundled_strategy_option
		strategy "freedesktop"
		out = `zap -nsdangerous_rm -- '#{@filename}' 2>&1`.b
		assert $?.success?
		assert_match(/Using strategy: dangerous_rm/, out)
		assert File.exist? @filename
	end

	def test_freedesktop_failed_move_leaves_no_trashinfo
		skip "running as root" if Process.uid == 0
		strategy "freedesktop"
		with_isolated_trash do |trash|
			FileUtils.mkdir_p ["#{trash}/files", "#{trash}/info"]
			FileUtils.chmod 0o500, "#{trash}/files"
			begin
				[[], ["-f"]].each do |flags|
					system "zap", *flags, "--", @filename, out: File::NULL, err: File::NULL
					refute $?.success?
					assert File.exist? @filename
					assert_empty Dir.children("#{trash}/info")
				end
			ensure
				FileUtils.chmod 0o700, "#{trash}/files"
			end
		end
	end

	def test_list
		strategy "freedesktop"
		with_isolated_trash do
			File.write "a.txt", "a"
			File.write "b.txt", "b"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			system "zap", "--", "b.txt", out: File::NULL, exception: true
			out = `zap --list`.b
			assert $?.success?
			lines = out.lines.map(&:chomp).select { _1.end_with?("/a.txt", "/b.txt") }
			assert_equal ["#{FileUtils.pwd}/a.txt", "#{FileUtils.pwd}/b.txt"], lines.map { _1.split("\t", 2)[1] }
			lines.each { assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\t/, _1) }
		end
	end

	def test_list_and_restore_ignore_strategy
		with_isolated_trash do
			strategy "freedesktop"
			File.write "a.txt", "a"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			strategy "dangerous_rm"
			listing = `zap --list`.b
			assert $?.success?
			assert listing.lines.any? { _1.end_with?("\t#{FileUtils.pwd}/a.txt\n".b) }
			system "zap", "--restore", "--", "a.txt", out: File::NULL, exception: true
			assert_equal "a", File.read("a.txt")
		end
	end

	def test_restore_round_trip
		strategy "freedesktop"
		with_isolated_trash do |trash|
			system "zap", "--", @filename, out: File::NULL, exception: true
			refute File.exist? @filename
			system "zap", "--restore", "--", @filename, out: File::NULL, exception: true
			assert_equal @contents, File.binread(@filename)
			assert_empty Dir.children("#{trash}/info")
			assert_empty Dir.children("#{trash}/files")
		end
	end

	def test_restore_refuses_to_overwrite
		strategy "freedesktop"
		with_isolated_trash do |trash|
			system "zap", "--", @filename, out: File::NULL, exception: true
			File.write @filename, "new"
			system "zap", "--restore", "--", @filename, out: File::NULL, err: File::NULL
			refute $?.success?
			assert_equal "new", File.read(@filename)
			assert_equal 1, Dir.children("#{trash}/info").length
		end
	end

	def test_restore_picks_newest
		strategy "freedesktop"
		with_isolated_trash do
			system "zap", "--", @filename, out: File::NULL, exception: true
			sleep 1.1 # DeletionDate has one-second resolution
			File.write @filename, "newer"
			system "zap", "--", @filename, out: File::NULL, exception: true
			system "zap", "--restore", "--", @filename, out: File::NULL, exception: true
			assert_equal "newer", File.read(@filename)
			File.delete @filename
			system "zap", "--restore", "--", @filename, out: File::NULL, exception: true
			assert_equal @contents, File.binread(@filename)
		end
	end

	def test_restore_missing
		strategy "freedesktop"
		with_isolated_trash do
			system "zap", "--restore", "--", "never-trashed", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
		end
	end

	def test_macos_mv_record_and_restore
		strategy "macos_mv"
		with_fake_home do |home|
			system "zap", "--", @filename, out: File::NULL, exception: true
			refute File.exist? @filename
			assert_equal 1, zap_records(home).length
			info = File.read(zap_records(home).first)
			assert_match(/^X-Zap-Strategy=macos_mv$/, info)
			assert_match(/^X-Zap-Inode=\d+$/, info)
			system "zap", "--restore", "--", @filename, out: File::NULL, exception: true
			assert_equal @contents, File.binread(@filename)
			assert_empty zap_records(home)
			assert_empty Dir.children("#{home}/.Trash")
		end
	end

	def test_macos_mv_restore_after_rename_in_trash
		strategy "macos_mv"
		with_fake_home do |home|
			File.write "a.txt", "a"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			# Simulate Finder renaming the item.
			File.rename "#{home}/.Trash/a.txt", "#{home}/.Trash/a 2.txt"
			system "zap", "--restore", "--", "a.txt", out: File::NULL, exception: true
			assert_equal "a", File.read("a.txt")
			assert_empty Dir.children("#{home}/.Trash")
		end
	end

	def test_macos_mv_name_clash
		strategy "macos_mv"
		with_fake_home do |home|
			File.write "a.txt", "older"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			sleep 1.1 # DeletionDate has one-second resolution
			File.write "a.txt", "newer"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			assert_equal 2, Dir.children("#{home}/.Trash").length
			system "zap", "--restore", "--", "a.txt", out: File::NULL, exception: true
			assert_equal "newer", File.read("a.txt")
			File.delete "a.txt"
			system "zap", "--restore", "--", "a.txt", out: File::NULL, exception: true
			assert_equal "older", File.read("a.txt")
		end
	end

	def test_macos_mv_stale_record
		strategy "macos_mv"
		with_fake_home do |home|
			File.write "a.txt", "a"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			# Simulate emptying the trash.
			File.delete "#{home}/.Trash/a.txt"
			refute_match(/a\.txt/, `zap --list`)
			system "zap", "--restore", "--", "a.txt", out: File::NULL, err: File::NULL
			refute $?.success?
			refute File.exist? "a.txt"
		end
	end

	def restore_round_trip_with(strat)
		strategy strat
		with_isolated_trash do
			File.write "a.txt", "a"
			system "zap", "--", "a.txt", out: File::NULL, err: File::NULL, exception: true
			refute File.exist? "a.txt"
			yield ENV['XDG_DATA_HOME'] if block_given?
			system "zap", "--restore", "--", "a.txt", out: File::NULL, exception: true
			assert_equal "a", File.read("a.txt")
		end
	end

	def test_trash_cli_restore
		skip "trash CLI not available" unless system "which trash-put", out: File::NULL, err: File::NULL
		restore_round_trip_with "trash_cli"
	end

	def test_gio_restore
		skip "gio CLI not available" unless system "which gio", out: File::NULL, err: File::NULL
		restore_round_trip_with "gio"
	end

	def macos_trash_readable?
		`uname -s`.chomp == 'Darwin' && (Dir.children("#{Dir.home}/.Trash") rescue false)
	end

	def test_macos_trash_command_restore
		skip "not on mac, or ~/.Trash not readable" unless macos_trash_readable? && File.executable?("/usr/bin/trash")
		restore_round_trip_with("macos_trash_command") do |xdg|
			# The record should point into ~/.Trash, spelled correctly even on a
			# case-insensitive filesystem where ~/.trash is the same directory.
			record = Dir.glob("#{xdg}/zap/info/*.trashinfo").first
			assert_match(%r{^X-Zap-TrashedPath=#{Regexp.escape(Dir.home)}/\.Trash/a\.txt}, File.read(record))
		end
	end

	def test_macos_applescript_restore
		skip "not on mac, or ~/.Trash not readable" unless macos_trash_readable?
		restore_round_trip_with "macos_applescript"
	end

	def test_refuses_trailing_newline
		strategy "freedesktop"
		with_isolated_trash do |trash|
			File.write "end\n", "x"
			File.write "good", "g"
			err = IO.popen(["zap", "--", "good", "end\n"], err: [:child, :out], &:read)
			refute $?.success?
			assert_match(/newline/, err)
			assert File.exist? "end\n"
			assert File.exist? "good"

			system "zap", "-f", "--", "end\n", "good", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
			assert File.exist? "end\n"
			refute File.exist? "good"

			system "zap", "--restore", "--", "end\n", out: File::NULL, err: File::NULL
			refute $?.success?
		end
	end

	def test_force_ignores_missing_files
		strategy "freedesktop"
		with_isolated_trash do
			out = `zap -f -- does-not-exist 2>&1`
			assert $?.success?
			refute_match(/does not exist/, out)
		end
	end

	def test_force_skips_untrashable_and_exits_1
		skip "running as root" if Process.uid == 0
		strategy "freedesktop"
		with_isolated_trash do |trash|
			FileUtils.mkdir "ro"
			File.write "ro/child", "c"
			File.write "good", "g"
			FileUtils.chmod 0o555, "ro"
			begin
				system "zap", "-f", "--", "ro/child", "good", out: File::NULL, err: File::NULL
				assert_equal 1, $?.exitstatus
				assert File.exist? "ro/child"
				refute File.exist? "good"
				assert_equal ["good"], Dir.children("#{trash}/files")
			ensure
				FileUtils.chmod 0o755, "ro"
			end
		end
	end

	def test_fail_fast_on_trash_directory
		strategy "freedesktop"
		with_isolated_trash do |trash|
			FileUtils.mkdir_p "#{trash}/files"
			File.write "#{trash}/files/inside", "i"
			File.write "good", "g"
			system "zap", "--", "good", "#{trash}/files/inside", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
			assert File.exist? "good"
			assert File.exist? "#{trash}/files/inside"

			# -f doesn't override this, but still trashes everything else.
			system "zap", "-f", "--", "good", "#{trash}/files/inside", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
			refute File.exist? "good"
			assert File.exist? "#{trash}/files/inside"
		end
	end

	def assert_cross_fs_refused(trash, dir, flags: [])
		File.write "#{dir}/good", "g"
		system "zap", *flags, "--", "#{dir}/good", "#{dir}/d", out: File::NULL, err: File::NULL
		assert_equal 1, $?.exitstatus
		assert File.exist? "#{dir}/d/inner"
		refute Dir.exist?("#{trash}/files/d"), "partial copy left in trash"
		refute File.exist?("#{trash}/info/d.trashinfo")
		if flags.include? "-f"
			refute File.exist? "#{dir}/good"
		else
			assert File.exist? "#{dir}/good"
		end
	end

	def test_cross_fs_unreadable_file_in_directory
		strategy "freedesktop"
		[[], ["-f"]].each do |flags|
			with_isolated_trash do |trash|
				with_tmpfs do |dir|
					FileUtils.mkdir "#{dir}/d"
					File.write "#{dir}/d/inner", "i"
					FileUtils.chmod 0o000, "#{dir}/d/inner"
					assert_cross_fs_refused trash, dir, flags: flags
				end
			end
		end
	end

	def test_cross_fs_read_only_subdirectory
		strategy "freedesktop"
		[[], ["-f"]].each do |flags|
			with_isolated_trash do |trash|
				with_tmpfs do |dir|
					FileUtils.mkdir_p "#{dir}/d/sub"
					File.write "#{dir}/d/inner", "i"
					File.write "#{dir}/d/sub/x", "x"
					FileUtils.chmod 0o555, "#{dir}/d/sub"
					assert_cross_fs_refused trash, dir, flags: flags
				end
			end
		end
	end

	def test_cross_fs_directory_ok
		strategy "freedesktop"
		with_isolated_trash do |trash|
			with_tmpfs do |dir|
				FileUtils.mkdir_p "#{dir}/d/sub"
				File.write "#{dir}/d/sub/x", "x"
				system "zap", "--", "#{dir}/d", out: File::NULL, err: File::NULL, exception: true
				refute Dir.exist? "#{dir}/d"
				assert_equal "x", File.read("#{trash}/files/d/sub/x")
			end
		end
	end

	def test_force_read_only_directory_refused
		skip "running as root" if Process.uid == 0
		strategy "freedesktop"
		with_isolated_trash do |trash|
			FileUtils.mkdir "d"
			File.write "d/inner", "i"
			FileUtils.chmod 0o555, "d"
			begin
				err = IO.popen(["zap", "-f", "--", "d"], err: [:child, :out], &:read)
				assert_equal 1, $?.exitstatus
				assert_match(/requires write permission/, err)
				refute_match(/^mv: /, err)
				assert File.exist? "d/inner"
				assert_empty Dir.glob("#{trash}/{files,info}/*")
			ensure
				FileUtils.chmod 0o755, "d"
			end
		end
	end

	def test_restore_fail_fast
		strategy "freedesktop"
		with_isolated_trash do
			File.write "a.txt", "a"
			system "zap", "--", "a.txt", out: File::NULL, exception: true
			system "zap", "--restore", "--", "a.txt", "never-trashed", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
			refute File.exist? "a.txt"

			system "zap", "--restore", "--", "a.txt", "a.txt", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
			refute File.exist? "a.txt"

			system "zap", "-f", "--restore", "--", "a.txt", "never-trashed", out: File::NULL, err: File::NULL
			assert_equal 1, $?.exitstatus
			assert_equal "a", File.read("a.txt")
		end
	end

	def test_restore_cross_fs_unreadable_refused
		strategy "freedesktop"
		with_isolated_trash do |trash|
			with_tmpfs do |dir|
				FileUtils.mkdir "#{dir}/d"
				File.write "#{dir}/d/inner", "i"
				system "zap", "--", "#{dir}/d", out: File::NULL, err: File::NULL, exception: true
				FileUtils.chmod 0o000, "#{trash}/files/d/inner"
				begin
					system "zap", "--restore", "--", "#{dir}/d", out: File::NULL, err: File::NULL
					assert_equal 1, $?.exitstatus
					refute File.exist? "#{dir}/d"
					assert File.exist? "#{trash}/files/d/inner"
					assert File.exist? "#{trash}/info/d.trashinfo"
				ensure
					FileUtils.chmod 0o644, "#{trash}/files/d/inner"
				end
			end
		end
	end
end
