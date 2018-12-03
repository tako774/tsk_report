# coding: utf-8

require 'nkf'

# convert $stdout to cp932
if !defined?($stdout._write)
  class << $stdout
    alias :_write :write
    def write(str)
	  # for Windows 10 October 2018 Update
	  # to write stdout, string should be started with ASCII code
      _write NKF.nkf('-sxm0 --cp932', "\x20\x08#{str.to_s}")
    end
  end
end
