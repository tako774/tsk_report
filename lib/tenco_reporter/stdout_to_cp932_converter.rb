# coding: utf-8

require 'nkf'

# convert $stdout to cp932
if !defined?($stdout._write)
  class << $stdout
    alias :_write :write
    def write(str)
      _write NKF.nkf('-sxm0 --cp932', str.to_s)
    end
  end
end
