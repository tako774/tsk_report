# coding: utf-8

require 'sqlite3'
require 'rexml/document'
require 'nkf'
require 'time'

module TencoReporter
  module TrackRecordUtil
  
    # 試合結果データ読み込み
    def read_trackrecord(db_files, last_report_time = Time.at(0))
      trackrecord = []
      
      db_files.each do |db_file|
        puts "#{NKF.nkf('-Swxm0 --cp932', db_file)} から対戦結果を抽出...\n"
        begin
          trackrecord.concat(_read_trackrecord(db_file, last_report_time + 1))
        rescue => ex
          is_warning_exist = true
          puts "！警告"
          puts ex.to_s
          puts "処理を続行します..."
          puts
        end
      end
      
      ## 報告対象データのデータ形式変換・文字コード変換・重複削除

      # タイムスタンプをFILETIMEからISO8601形式に変換
      trackrecord.each do |t|
        t['timestamp'] = filetime_to_iso8601(t['timestamp'])
      end

      # もしタイムスタンプが一定時時間以内のデータがあれば、古いほうを残して報告対象からはずす
      # 1行1行のハッシュを別レコードとして扱うため、連番をふる
      trackrecord.each_index do |i|
        trackrecord[i]['seq'] = i
      end
      
      trackrecord = delete_duplicated_trackrecord(trackrecord)
      
      # 文字列をutf-8に変換
      # TODO 現状は shift-jis -> utf8 + 半角カナ→全角カナの変換になってしまっているが、
      # 本来は、以下のコードで cp932 -> utf8 の変換にしたい
      # NKF.nkf('-Sw --cp932 -x -m0', str)
      # ただし、変更前と変更後では別の文字列になるため、マッチングを考慮してそのままにしておく
      trackrecord.each do |t|
        #t['p1name'] = NKF.nkf('-Swxm0 --cp932', t['p1name'])
        #t['p2name'] = NKF.nkf('-Swxm0 --cp932', t['p2name'])
        t['p1name'] = NKF.nkf('-Swm0 --cp932', t['p1name'])
        t['p2name'] = NKF.nkf('-Swm0 --cp932', t['p2name'])
      end
      
      return trackrecord
      
    end
  
    # 指定されたDBファイルから試合結果データ読み込み
    # 発生時間が古い順にデータを並べて返す
    # 指定されたデータベースファイルが存在しなければ、例外を発生させる
    # db_file 名は cp932 で渡すこと
    def _read_trackrecord(db_file_cp932, last_report_time = Time.at(0))
      
      trackrecord = []
      db_file_utf8 = NKF.nkf('-Swxm0 --cp932', db_file_cp932)
      
      # DB接続
      # DBファイルがなければ例外発生
      raise <<-MSG unless File.exist? db_file_cp932
 #{RECORD_SW_NAME}データベースファイルが見つかりません。(パス：#{db_file_utf8})
・エクスプローラー上で見て、もし該当パス名のファイルがあり、サイズが0KBであれば、削除してください
  一部の特殊な文字を含むDBファイル名は、正常に読み込みができないかもしれません。
  ファイル名を変更することで解決する可能性があります。
      #{ex.to_s}
      #{ex.backtrace.join("\n")}
      MSG

      # DBファイルサイズが0なら処理スキップ
      if File.size?(db_file_cp932) == 0
        puts "！ファイルサイズが 0KB です(パス：#{db_file_utf8})。処理をスキップします。"
        return trackrecord
      end
      
      begin
        begin
          db = SQLite3::Database.open(db_file_utf8)
          # SQLite3 モジュールの UTF16 ファイル名対応をONにした場合の読み込み
          # ただ、UTF16対応の必要なファイル名だと、テーブル名が見つからないなど、データが読めないことがある。理由は謎。
          # db = SQLite3::Database.open(NKF.nkf('-Sw16xm0 --cp932' ,db_file), {:utf16 => true})
          db.results_as_hash = true
        rescue => ex
          raise <<-MSG
#{RECORD_SW_NAME}データベースファイルへの接続に失敗しました。(パス：#{db_file_utf8})
・エクスプローラー上で見て、もし該当パス名のファイルがあり、サイズが0KBであれば、削除してください
  一部の特殊な文字を含むDBファイル名は、正常に読み込みができないかもしれません。
  ファイル名を変更することで解決する可能性があります。
#{ex.to_s}
#{ex.backtrace.join("\n")}
          MSG
        end
        
        # 試合結果記録の読み込み
        sql = <<-SQL
          SELECT
            *
          FROM
            #{DB_TR_TABLE_NAME}
          WHERE
              timestamp > #{time_to_filetime(last_report_time).to_i}
            AND COALESCE(p1name, '') != ''
            AND p1id >= 0
            AND p1win >= 0
            AND COALESCE(p2name, '') != ''
            AND p2id >= 0
            AND p2win >= 0
          ORDER BY
            timestamp
        SQL

        begin
          db.execute(sql) do |row|
            row["p1name"] = row["p1name"].to_s
            row["p2name"] = row["p2name"].to_s
            trackrecord << row
          end
        rescue => ex
          raise <<-MSG
#{RECORD_SW_NAME}データベースへの、対戦結果取得SQLクエリ発行時にエラーが発生しました。(パス：#{db_file_utf8})
・エクスプローラー上で見て、もし該当パス名のファイルがあり、サイズが0KBであれば、削除してください
　一部の特殊な文字を含むDBファイル名は、正常に読み込みができないかもしれません。
　ファイル名を変更することで解決する可能性があります。
#{ex.to_s}
#{ex.backtrace.join("\n")}
          MSG
        end
          
      rescue => ex
        raise ex.to_s
      ensure
        db.close if db
      end
      
      return trackrecord
    end
    
    # タイムスタンプが一定時間内に連続するデータを削除
    def delete_duplicated_trackrecord(trackrecord)
      last_timestamp = nil    # 直前のデータのタイムスタンプ
      delete_trackrecord = [] # 削除対象のデータ
      
      # タイムスタンプ順にソート
      trackrecord = trackrecord.sort_by {|t| Time.parse(t['timestamp'])}

      # 重複レコードを取得
      trackrecord.each do |t|
        timestamp = Time.parse(t['timestamp'])
        
        unless last_timestamp
          last_timestamp = timestamp
        else
          if timestamp <= last_timestamp + DUPLICATION_LIMIT_TIME_SECONDS
            delete_trackrecord << t
          else
            last_timestamp = timestamp
          end
        end
      end
      
      if delete_trackrecord.length > 0 then
        puts "#{delete_trackrecord.length} 件のデータは、重複データと疑われるため報告されません。"
        puts
      end
      
      return trackrecord - delete_trackrecord
    end

    # 対戦結果データをポスト用XMLに変換
    def trackrecord2xml_string(game_id, account_name, account_password, trackrecord, is_force_insert)
      # XML生成
      xml = REXML::Document.new
      xml << REXML::XMLDecl.new('1.0', 'UTF-8')
      
      # trackrecordPosting 要素生成
      root = xml.add_element('trackrecordPosting')
      
      # account 要素生成
      account_element = root.add_element('account')
      account_element.add_element('name').add_text(account_name.to_s)
      account_element.add_element('password').add_text(Digest::SHA1.hexdigest(account_password.to_s))
      
      # game 要素生成
      game_element = root.add_element('game')
      game_element.add_element('id').add_text(game_id.to_s)
      
      # trackrecord 要素生成
      trackrecord.each do |t|
        trackrecord_element = game_element.add_element('trackrecord')
        trackrecord_element.add_element('timestamp').add_text(t['timestamp'].to_s)
        trackrecord_element.add_element('p1name').add_text(t['p1name'].to_s)
        trackrecord_element.add_element('p1type').add_text(t['p1id'].to_s)
        trackrecord_element.add_element('p1point').add_text(t['p1win'].to_s)
        trackrecord_element.add_element('p2name').add_text(t['p2name'].to_s)
        trackrecord_element.add_element('p2type').add_text(t['p2id'].to_s)
        trackrecord_element.add_element('p2point').add_text(t['p2win'].to_s)
      end
      
      # 強制インサート依頼時には、is_force_insert を true にする
      # is_force_insert 要素生成
      if is_force_insert then
        root.add_element('is_force_insert').add_text('true')
      end
      
      return xml.to_s
    end
    
    # 緋行跡/天則観のタイムスタンプ (FILETIME)を ISO8601 形式に変換
    # FILETIME は 1601年1月1日からの100ナノ秒単位での時間
    # 緋行跡/天則観はローカル時刻を取得しているので、ローカルの時刻オフセットをつける
    def filetime_to_iso8601(filetime)
      # DateTime モジュールだと計算精度が低かったので Time モジュールを利用
      if filetime then
        base_filetime = 126227808000000000   # 2001年1月1日0時の FILETIME
        base_time = Time.local(2001, 1, 1)
        time = base_time + (filetime.to_i - base_filetime) / 10.0**7
        return time.iso8601
      else
        return nil
      end
    end

    # Time型のインスタンス を FILETIME に変換
    # FILETIME は 1601年1月1日からの100ナノ秒単位でのローカル時間
    def time_to_filetime(time)
      if time then
          base_filetime = 126227808000000000   # 2001年1月1日0時の FILETIME
        base_time = Time.local(2001, 1, 1)
        return base_filetime + (time - base_time) * 10**7
      else
        return nil
      end
    end
    
  end
end

