# coding: utf-8

require 'yaml'

module TencoReport
  module ConfigUtil

    # ファイルからコンフィグをロード
    def load_config(config_file)
      # 設定ファイルの UTF-8 に対応するため、一旦 UTF-8N に変換する。
      config = YAML.load(NKF.nkf('-wxm0', File.read(config_file)))
      # to_yaml をマルチバイト文字対応
      class << config
        alias :_to_yaml :to_yaml
        def to_yaml
          _to_yaml.syck_unescape
        end
      end
      
      config || {}
    end
    
    # コンフィグファイル保存
    def save_config(config_file, config)
      File.open(config_file, 'w') do |w|
        w.puts "# #{PROGRAM_NAME}設定ファイル"
        w.puts "# かならず文字コードは UTF-8 または UTF-8N で保存してください。"
        w.puts "# メモ帳でも編集・保存できます。"
        w.puts config.to_yaml
      end
    end
    
  end
end

class String
  # String.is_binary_data?で必ずfalseを返すように書き換える
  # YAML(syck) にマルチバイト文字をバイナリと間違えられないようにする
  def is_binary_data?
    false
  end
  
  # YAML(syck) の to_yaml が ASCII 範囲外の文字を 
  # \x00 形式でエスケープするので、アンエスケープする
  def syck_unescape
    gsub(/\\x(\w{2})/) { [Regexp.last_match.captures.first.to_i(16)].pack("C") }
  end
end
