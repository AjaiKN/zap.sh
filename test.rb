#!/usr/bin/env ruby

require "minitest/autorun"
require "uri"

def strategy strat
	ENV['TRASH_STRATEGY'] = strat
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
	# NOTE: Linux has a max file length (lower than the max for Mac)
	ret += '折り紙🕊é é﷽ᄀᄀᄀ각ᆨᆨ🇺🇸각नीநி﷽&ᄀᄀᄀ각ᆨᆨ🇺🇸각नीநி👩‍👩‍👦‍👦&👩‍👩‍👦‍👦&'
	ret
end

TEST_CHARS = test_chars
# TEST_CHARS = ''

class TestTrash < Minitest::Test
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
		puts `trash -v -- '#{@filename}'`
		refute $?.success?
		assert File.exist? @filename
	end

	def test_freedesktop
		strategy "freedesktop"
		FileUtils.touch @filename
		puts `trash -v -- '#{@filename}'`
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
		strategy "trash_cli"
		FileUtils.touch @filename
		puts `trash -v -- '#{@filename}'`
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
		strategy "gio"
		FileUtils.touch @filename
		puts `trash -v -- '#{@filename}'`
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
		puts `trash -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{Dir.home}/.Trash/#{@filename}"
		assert_equal @contents, File.binread("#{Dir.home}/.Trash/#{@filename}")
	end

	def test_macos_applescript
		skip "not on mac" unless `uname -s`.chomp == 'Darwin'
		strategy "macos_applescript"
		FileUtils.touch @filename
		puts `trash -v -- '#{@filename}'`
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
		puts `trash -v -- '#{@filename}'`
		assert $?.success?
		refute File.exist? @filename
		assert File.exist? "#{Dir.home}/.Trash/#{@filename}"
		assert_equal @contents, File.binread("#{Dir.home}/.Trash/#{@filename}")
	end
end
