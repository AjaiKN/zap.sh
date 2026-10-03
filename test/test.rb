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

	def test_list_unsupported_strategy
		strategy "dangerous_rm"
		system "zap", "--list", out: File::NULL, err: File::NULL
		assert_equal 1, $?.exitstatus
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
end
