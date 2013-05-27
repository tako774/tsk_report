# coding: utf-8
require 'zlib'
require 'rexml/document'

class String
  def pass(enc)
    self
  end
  alias :force_encoding :pass if !self.new.respond_to?(:force_encoding)
end

module TencoReport
  module ReplayUtil
    
    # 対戦結果に対応する対戦結果とリプレイファイルパスを取得
    # file_num を上限個数とする
    def get_replay_files(trackrecords, replay_config_path, file_num)
      replay_format = get_replay_format(replay_config_path)
      #日付記号　%year %month %day
      #日付一括記号　%yymmdd %mmdd
      #時刻記号　%hour %min %sec
      #時刻一括記号　%hhmmss %hhmm
      #使用プロファイル　%p1 %p2
      #使用キャラクター　%c1 %c2
      #日付記号　%y %m %d (天則:実装しない)
      #時刻記号　%h %min %sec (天則:実装しない)
      pattern = /%(year|month|day|yymmdd|yymm|hour|min|sec|hhmmss|hhmm|p1|p2|c1|c2)/
      replay_files = []
      trackrecords.shuffle.each do |tr|
        tr_time = Time.parse(tr['timestamp'])
        tr_replay_files = [tr_time - 15, tr_time, tr_time + 15].map do |time|
          conversion = {
            "%year"   => time.year.to_s[2..3],
            "%month"  => sprintf("%02d", time.month),
            "%day"    => sprintf("%02d", time.day),
            "%yymm"   => time.year.to_s[2..3] + sprintf("%02d", time.month),
            "%yymmdd" => time.year.to_s[2..3] + sprintf("%02d", time.month) + sprintf("%02d", time.day),
            "%hour"   => sprintf("%02d", time.hour),
            "%min"    => sprintf("%02d", time.min),
            "%sec"    => "*", # 結果記録とリプレイファイルのタイムスタンプは7秒くらいはずれる
            "%hhmm"   => sprintf("%02d", time.hour) + sprintf("%02d", time.min),
            "%hhmmss" => sprintf("%02d", time.hour) + sprintf("%02d", time.min) + "*",
            "%p1" => tr['p1name'],
            "%p2" => tr['p2name'],
            "%c1" => "*",
            "%c2" => "*"
          }
          replay_file_pattern = replay_format.gsub(pattern) { |str| conversion[str] }
          replay_file_pattern = "#{File.dirname(replay_config_path)}\\replay\\#{replay_file_pattern}*"
          replay_file_pattern.gsub!("\\", "/")
          replay_file_pattern.gsub!(/\*+/, "*")
          replay_file_pattern_cp932 = NKF.nkf('-sWxm0 --cp932', replay_file_pattern)
          Dir.glob(replay_file_pattern_cp932)
        end
        
        tr_replay_files.flatten!.uniq!
        if !tr_replay_files[0].nil? then
          replay_files.push({ :trackrecord => tr, :path => tr_replay_files[0] })
          if replay_files.length >= file_num then
            replay_files = replay_files[0..(file_num - 1)]
            break
          end
        else
          # puts "リプレイファイルが見つけられませんでした。"
        end
        
      end
      replay_files
    end

    # リプレイデータ引数とし、匿名化したデータを返す
    def mask_replay_data(data)
      meta_data_length = get_meta_data_length(data)
      
      meta_data = inflate_meta_data(data)
      masked_meta_data = mask_meta_data(meta_data)
      compressed_masked_meta_data = Zlib::Deflate.deflate(masked_meta_data)
     
      data.slice(0, 9) +
      [compressed_masked_meta_data.length + 8].pack("I") + 
      [compressed_masked_meta_data.length].pack("I") + 
      [masked_meta_data.length].pack("I") + 
      compressed_masked_meta_data +
      data[(21 + meta_data_length)..-1]
    end
    
    # replayPosting XML生成
    def make_replay_posting_xml(trackrecord, game_id, account_name, account_password)
      xml = REXML::Document.new
      xml << REXML::XMLDecl.new('1.0', 'UTF-8')
      
      # replayPosting 要素生成
      root = xml.add_element('replayPosting')
      
      # account 要素生成
      account_element = root.add_element('account')
      account_element.add_element('name').add_text(account_name.to_s)
      account_element.add_element('password').add_text(account_password.to_s)
      
      # game 要素生成
      game_element = root.add_element('game')
      game_element.add_element('id').add_text(game_id.to_s)
      
      # trackrecord 要素生成
      trackrecord_element = game_element.add_element('trackrecord')
      trackrecord_element.add_element('timestamp').add_text(trackrecord['timestamp'].to_s)
      trackrecord_element.add_element('p1name').add_text(trackrecord['p1name'].to_s)
      trackrecord_element.add_element('p1type').add_text(trackrecord['p1id'].to_s)
      trackrecord_element.add_element('p1point').add_text(trackrecord['p1win'].to_s)
      trackrecord_element.add_element('p2name').add_text(trackrecord['p2name'].to_s)
      trackrecord_element.add_element('p2type').add_text(trackrecord['p2id'].to_s)
      trackrecord_element.add_element('p2point').add_text(trackrecord['p2win'].to_s)
      
      xml.to_s
    end
    
    private

    # ゲーム側のリプレイファイル名のフォーマット設定を取得
    def get_replay_format(replay_config_path)
      replay_format = nil
      File.open(replay_config_path, "r") do |io|
        while (line = io.gets) do
          if line.strip =~ /\Afile_vs="?([^"]+)"?\z/ then
            replay_format = $1
            break
          end
        end
      end
      replay_format
    end
        
    # 元の圧縮された状態でのメタデータの長さを取得する
    # 9byte TFRAP 00 65 00 00 00
    # 4byte first_block_length (= compressed data length + 8)
    # 4byte compressed meta data length
    # 4byte uncompressed meta data length
    # zlib compressed meta data
    # rest data
    def get_meta_data_length(data)
      idx = 13
      data.slice(idx, 4).unpack("I")[0]
    end
    
    # メタデータを展開する
    def inflate_meta_data(meta_data)
      idx = 21
      compressed_len = get_meta_data_length(meta_data)
      
      block_data = meta_data.slice(idx, compressed_len)
      # zlib header : 78 9C
      if block_data.slice(0, 2) == "\x78\x9c".force_encoding('ASCII-8BIT') then
        inflate_data = Zlib::Inflate.inflate(block_data)
        return inflate_data
      else
        raise "ERROR: zlib header invalide (#{block_data.slice(0, 2)} != \"\x78\x9c\")"
      end
    end
    
    # メタデータをマスクする
    def mask_meta_data(meta_data)
      data = meta_data.clone
      keys = %w(icon_dump icon inner_name name)
      keys.each do |key|
        search_key = key.force_encoding('ASCII-8BIT') + "\x10\x00\x00\x08".force_encoding('ASCII-8BIT')
        idx = -1
        while (idx = data.index(search_key, idx + 1)) do
          idx += (key.bytesize + 4)
          len = data.slice(idx, 4).unpack("I")[0]
          idx += 4
          if key == "icon_dump" then
            # <width>,<height>,<unknown digit>,<body>
            vals = data[idx, len].split(",")
            # if masked with other byte, th135 will crash
            vals[vals.size - 1] = "\x2F".force_encoding('ASCII-8BIT') * vals[vals.size - 1].bytesize
            data[idx, len] = vals.join(",")
          else
            data[idx, len] = "\x00".force_encoding('ASCII-8BIT') * len
          end
        end
      end
      data
    end
  end  
end
