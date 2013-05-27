# coding: utf-8
require 'zlib'
require 'rexml/document'

module TencoReport
  module HttpUtil
    
    # HTTP Multipart 用のリクエストボディ・リクエストヘッダ生成
    # 引数として、name => データ本体のハッシュを渡すと、
    # HTTP Multipart 用のリクエストボディ・リクエストヘッダを返す
    def make_http_multipart_data(http_multipart_data)
      boundary = "#{("0".."9").to_a.shuffle.join}"
      body = ""
      header = {}
      
      # ボディ部
      http_multipart_data.each do |name, data|
        body += "--#{boundary}\r\n"
        body += "content-disposition: form-data; name=\"#{name.to_s}\"\r\n"
        body += "\r\n"
        body += "#{data}\r\n"
      end
      body += "--#{boundary}--\r\n"
      
      # ヘッダ部
      header["content-type"] = "multipart/form-data; boundary=#{boundary}"
      header["content-length"] = body.bytesize.to_s
      
      {:body => body, :header => header}
    end
    
  end  
end
