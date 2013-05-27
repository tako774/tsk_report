# coding: utf-8

require 'rubygems'
require 'nkf'
require 'net/http'
Net::HTTP.version_1_2
require 'rexml/document'
require 'time'
require 'digest/sha1'
require 'optparse'

$LOAD_PATH.unshift 'lib'

require 'tenco_report/config_util'
include TencoReport::ConfigUtil
require 'tenco_report/track_record_util'
include TencoReport::TrackRecordUtil
require 'tenco_report/replay_util'
include TencoReport::ReplayUtil
require 'tenco_report/http_util'
include TencoReport::HttpUtil
require 'tenco_report/stdout_to_cp932_converter'

# プログラム情報
PROGRAM_VERSION = '0.02'
PROGRAM_NAME = '綺録帖報告ツール'
PAST_PROGRAM_NAME = '他ゲームの報告ツール'
GAME_NAME = '東方心綺楼'
GAME_REPLAY_CONFIG_FILE_NAME = 'config.ini'

# デフォルト値
game_id = 4 # ゲームID
DEFAULT_DATABASE_FILE_PATH = '../*.db' # データベースファイルパス

# 設定
TRACKRECORD_POST_SIZE = 250 # 一度に送信する対戦結果数
DUPLICATION_LIMIT_TIME_SECONDS = 2 # タイムスタンプが何秒以内のデータを、重複データとみなすか
ACCOUNT_NAME_REGEX = /\A[a-zA-Z0-9_]{1,32}\z/
MAIL_ADDRESS_REGEX = /\A[\x01-\x7F]+@(([-a-z0-9]+\.)*[a-z]+|\[\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\])\z/ # メールアドレスチェック用正規表現
PASSWORD_REGEX = /\A[!-~]{8,16}\z/
PLEASE_RETRY_FORCE_INSERT = "<Please Retry in Force-Insert Mode>"  # 強制インサートリトライのお願い文字列
HTTP_REQUEST_HEADER = {"User-Agent" => "Tenco Report Tool/#{PROGRAM_VERSION} GAME ID #{game_id}"}
RECORD_SW_NAME = '綺録帖' # 対戦記録ソフトウェア名
DB_TR_TABLE_NAME = 'trackrecord135' # DBの対戦結果テーブル名
WEB_SERVICE_NAME = 'Tenco!'  # サーバ側のサービス名

# ログファイルパス
ERROR_LOG_PATH = 'error.txt'

# 送信設定
is_force_insert = false # 強制インサートモード。はじめは false。
is_all_report = false # 全件報告モード。サーバーからの最終対戦時刻をとらず、全件送信。

# 変数
latest_version = nil # クライアントの最新バージョン
trackrecord = [] # 対戦結果
is_read_trackrecord_warning = false # 対戦結果読み込み時に警告があったかどうか
is_warning_exist = false # 警告メッセージがあるかどうか
send_replay_file_num = 1 # 送るリプレイファイル数

puts "*** #{PROGRAM_NAME} ***"
puts "ver.#{PROGRAM_VERSION}\n\n"

begin

  ### 設定読み込み ###

  # 設定ファイルパス
  load_config_file = File.exist?('config.yaml') ? 'config.yaml' : 'config_default.yaml'
  save_config_file = 'config.yaml'
  env_file = 'env.yaml'

  # 設定ファイルがなければエラー終了
  unless File.exist?(load_config_file)
      raise "#{load_config_file} が見つかりません。\nダウンロードした#{PROGRAM_NAME}からコピーしてください。"
  end

  # サーバー環境設定ファイルがなければ、エラー終了
  unless File.exist?(env_file) then
    raise "#{env_file} が見つかりません。\nダウンロードした本プログラムのフォルダからコピーしてください。"
  end

  # 設定ファイル読み込み
  config = load_config(load_config_file)
  env    = load_config(env_file)

  config['account'] ||= {}
  config['database'] ||= {}
  config['replay'] ||= {}
  account_name = config['account']['name'].to_s || ''
  account_password = config['account']['password'].to_s || ''
  db_file_path = config['database']['file_path'].to_s || DEFAULT_DATABASE_FILE_PATH
  replay_config_path = config['replay']['config_path'] || ''
  is_send_replay = config['replay']['is_send_replay']

  SERVER_TRACK_RECORD_HOST = env['server']['track_record']['host'].to_s
  SERVER_TRACK_RECORD_PATH = env['server']['track_record']['path'].to_s
  SERVER_LAST_TRACK_RECORD_HOST = env['server']['last_track_record']['host'].to_s
  SERVER_LAST_TRACK_RECORD_PATH = env['server']['last_track_record']['path'].to_s
  SERVER_ACCOUNT_HOST = env['server']['account']['host'].to_s
  SERVER_ACCOUNT_PATH = env['server']['account']['path'].to_s
  SERVER_REPLAY_UPLOAD_HOST = env['server']['replay_upload']['host'].to_s
  SERVER_REPLAY_UPLOAD_PATH = env['server']['replay_upload']['path'].to_s
  CLIENT_LATEST_VERSION_HOST = env['client']['latest_version']['host'].to_s
  CLIENT_LATEST_VERSION_PATH = env['client']['latest_version']['path'].to_s
  CLIENT_SITE_URL = "http://#{env['client']['site']['host']}#{env['client']['site']['path']}"

  ### クライアント最新バージョンチェック ###

  def get_latest_version(latest_version_host, latest_version_path)
    response = nil
    Net::HTTP.new(latest_version_host, 80).start do |s|
      response = s.get(latest_version_path, HTTP_REQUEST_HEADER)
    end
    response.code == '200' ? response.body.strip : nil
  end

  begin
    latest_version = get_latest_version(CLIENT_LATEST_VERSION_HOST, CLIENT_LATEST_VERSION_PATH)

    case
    when latest_version.nil?
      # puts "！最新バージョンの取得に失敗しました。"
      # puts "スキップして続行します。"
    when latest_version > PROGRAM_VERSION then
      puts "★新しいバージョンの#{PROGRAM_NAME}が公開されています。（ver.#{latest_version}）"
      puts "ブラウザを開いて確認しますか？（Nを入力するとスキップ）"
      print "> "
      case gets[0..0]
      when "N" then
        puts "スキップして続行します。"
        puts
      else
        system "start #{CLIENT_SITE_URL}"
        exit
      end
    when latest_version <= PROGRAM_VERSION then
      # puts "お使いのバージョンは最新です。"
      # puts
    end

  rescue => ex
    puts "！クライアント最新バージョン自動チェック中にエラーが発生しました。"
    puts ex.class
    puts ex.to_s
    # puts ex.backtrace.join("\n")
    puts
    puts "スキップして処理を続行します。"
    puts
  end

  ### メイン処理 ###

  ## オプション設定
  opt = OptionParser.new

  # 全件報告モード
  opt.on('-a') {|v| is_all_report = true}

  opt.parse! ARGV

  ## アカウント設定（新規アカウント登録／既存アカウント設定）処理
  unless (account_name && account_name =~ ACCOUNT_NAME_REGEX) then
    is_new_account = nil
    account_name = ''
    account_password = ''
    raw_account_password = ''
    account_mail_address = ''
    is_account_register_finish = false

    puts "★#{WEB_SERVICE_NAME} アカウント設定（初回実行時）"

    loop do
      puts "#{WEB_SERVICE_NAME} をはじめてご利用の場合、「1」をいれて Enter キーを押してください。"
      puts "すでに#{PAST_PROGRAM_NAME}等で #{WEB_SERVICE_NAME} アカウントを登録済みの場合、「2」をいれて Enter キーを押してください。"
      print "> "
      input = gets.strip
      if input == "1"
        is_new_account = true
        puts
        break
      elsif input == "2"
        is_new_account = false
        puts
        break
      end
    end

    # 新規アカウント登録
    if is_new_account then

      puts "★新規 #{WEB_SERVICE_NAME} アカウント登録\n\n"

      loop do

        # アカウント名入力
        loop do
          puts "希望アカウント名を入力してください"
          puts "アカウント名はマイページのURLの一部として使用されます。"
          puts "（半角英数とアンダースコア_のみ使用可能。32文字以内）"
          print "希望アカウント名> "
          input = gets.strip
          if input =~ ACCOUNT_NAME_REGEX then
            account_name = input
            ## TODO 既存アカウント存在チェック
            puts
            break
          end
        end
        
        # パスワード入力
        loop do
          puts "パスワードを入力してください（半角英数記号。8～16字以内。アカウント名と同一禁止。）"
          print "パスワード> "
          input = gets.strip
          if input =~ PASSWORD_REGEX then
            raw_account_password = input
            # パスワード確認入力
            print "パスワード（確認）> "
            input = gets.strip
            if (raw_account_password == input) then
              account_password = Digest::SHA1.hexdigest(raw_account_password)
              puts
              break
            else
              puts "！パスワードが一致しません\n"
            end
          end
          puts
        end

        # メールアドレス入力
        puts "メールアドレスを入力してください（任意）"
        puts "何も入力せず Enter を押すと、入力をスキップします。"
        puts "※パスワードを忘れたときのパスワードリセット時にのみ使用します。"
        puts "※サーバー上では、元のメールアドレスに戻せない形式へと暗号化し保存します。"
        puts "※このため登録したメールアドレスに対し、メールが送られることはありません。"
        loop do
          print "メールアドレス> "
          input = gets.strip
          if (input == '') then
            account_mail_address = ''
            puts "メールアドレスは登録いたしません。"
            puts
            break
          elsif input =~ MAIL_ADDRESS_REGEX && input.bytesize <= 256 then
            account_mail_address = input
            puts
            break
          else
            puts "！メールアドレスは正しい形式で、256byte以内にて入力してください"
          end
        end

        # 新規アカウントをサーバーに登録
        puts "サーバーにアカウントを登録しています...\n"

        # アカウント XML 生成
        account_xml = REXML::Document.new
        account_xml << REXML::XMLDecl.new('1.0', 'UTF-8')
        account_element = account_xml.add_element("account")
        account_element.add_element('name').add_text(account_name)
        account_element.add_element('password').add_text(raw_account_password)
        account_element.add_element('mail_address').add_text(account_mail_address)
        
        # サーバーに送信
        response = nil
        http = Net::HTTP.new(SERVER_ACCOUNT_HOST, 80).start do |s|
          response = s.post(SERVER_ACCOUNT_PATH, account_xml.to_s, HTTP_REQUEST_HEADER)
        end

        puts "サーバーからのお返事"
        response.body.each_line do |line|
          puts "> #{line}"
        end

        if response.code == '200' then
        # アカウント登録成功時
          config['account']['name'] = account_name
          config['account']['password'] = account_password

          save_config(save_config_file, config)

          puts
          puts "アカウント情報を設定ファイルに保存しました。"
          puts "サーバーからのお返事の内容をご確認ください。"
          puts
          puts "Enter キーを押すと、リプレイファイル設定に進みます‥‥。"
          gets

          puts
          break
        else
        # アカウント登録失敗時
          puts "もう一度アカウント登録をやり直します...\n\n"
          sleep 1
        end

      end
    else

      puts "★設定ファイル編集\n"
      puts "#{WEB_SERVICE_NAME} アカウント名とパスワードを設定します"
      puts "※アカウント名とパスワードが分からない場合、ご利用の#{WEB_SERVICE_NAME}クライアント（#{PAST_PROGRAM_NAME}等）の#{save_config_file}で確認できます"
      puts

      # アカウント名入力
      loop do
        puts "お持ちの #{WEB_SERVICE_NAME} アカウント名を入力してください"
        print "アカウント名> "
        input = gets.strip
        if input =~ ACCOUNT_NAME_REGEX then
          account_name = input
          ## TODO 既存アカウント存在チェック
          puts
          break
        end
      end
      
      # パスワード入力
      loop do
        puts "パスワードを入力してください"
        print "パスワード> "
        input = gets.strip
        account_password = Digest::SHA1.hexdigest(input)
        # パスワード確認入力
        print "パスワード（確認）> "
        input = gets.strip
        if (account_password == Digest::SHA1.hexdigest(input)) then
          if input !~ PASSWORD_REGEX then
            # puts "パスワードは、8～16文字以内が推奨です"
            # TODO: パスワード変更ウィザード
          end
          puts
          break
        else
          puts "！パスワードが一致しません\n"
        end
        puts
      end
      
      ## TODO アカウント認証確認
      
      # 設定ファイル保存
      config['account']['name'] = account_name
      config['account']['password'] = account_password
      save_config(save_config_file, config)

      puts "アカウント情報を設定ファイルに保存しました。\n\n"

    end # if is_new_account
    sleep 2
  end ## アカウント設定

  ## リプレイファイル設定
  if (is_send_replay.nil?) then
    
    puts "★リプレイファイル設定"
    puts "Tenco! サーバー上で公開するリプレイファイルの設定をします。"
    
    loop do
      puts "リプレイファイルを公開する場合は「1」、公開しない場合は「2」を入力してください。"
      puts "公開する設定にすると、自動的にランダムでリプレイファイルが公開されます。"
      puts "リプレイファイル中のプロフィール名・アイコンはすべて匿名化されます。"
      puts "公開されるのは、報告のたびにランダムで1ファイルのみです。"
      print "> "
      input = gets.strip
      if input == "1"
        is_send_replay = true
        puts "リプレイファイルを公開します。"
        break
      elsif input == "2"
        is_send_replay = false
        puts "リプレイファイルを公開しません。"
        puts 
        break
      end
    end
    
    if is_send_replay then
      loop do
        puts "#{GAME_NAME}フォルダの #{GAME_REPLAY_CONFIG_FILE_NAME} ファイルをこのウィンドウにドラッグアンドドロップし、Enterを入力してください。"
        print "> "
        input = gets.strip.gsub("\"", "")
        if File.file?(input)
          replay_config_path = input
          puts "リプレイファイル設定を完了しました。"
          puts "引き続き、報告処理を行います..."
          puts
          sleep 3
          break
        end
      end
    end
    
    config['replay']['config_path'] = replay_config_path || ''
    config['replay']['is_send_replay'] = is_send_replay
    save_config(save_config_file, config)
    
  end
  
  ## 登録済みの最終対戦結果時刻を取得する
  unless is_all_report then
    puts "★登録済みの最終対戦時刻を取得"
    puts "GET http://#{SERVER_LAST_TRACK_RECORD_HOST}#{SERVER_LAST_TRACK_RECORD_PATH}?game_id=#{game_id}&account_name=#{account_name}"

    response = nil
    Net::HTTP.new(SERVER_LAST_TRACK_RECORD_HOST, 80).start do |s|
      response = s.get("#{SERVER_LAST_TRACK_RECORD_PATH}?game_id=#{game_id}&account_name=#{account_name}", HTTP_REQUEST_HEADER)
    end

    if response.code == '200' || response.code == '204' then
      if (response.body && response.body != '') then
        last_report_time = Time.parse(response.body)
        puts "サーバー登録済みの最終対戦時刻：#{last_report_time.strftime('%Y/%m/%d %H:%M:%S')}"
      else
        last_report_time = Time.at(0)
        puts "サーバーには対戦結果未登録です"
      end
    else
      raise "最終対戦時刻の取得時にサーバーエラーが発生しました。処理を中断します。"
    end
  else
    puts "★全件報告モードです。サーバーからの登録済み最終対戦時刻の取得をスキップします。"
    last_report_time = Time.at(0)
  end
  puts

  ## 対戦結果報告処理
  puts "★対戦結果送信"
  puts ("#{RECORD_SW_NAME}の記録から、" + last_report_time.strftime('%Y/%m/%d %H:%M:%S') + " 以降の対戦結果を報告します。")
  puts

  # DBから対戦結果を取得
  db_files_cp932 = Dir::glob(NKF.nkf('-Wsxm0 --cp932', db_file_path))
  if db_files_cp932.length > 0
    trackrecords, is_read_trackrecord_warning = read_trackrecord(db_files_cp932, last_report_time)
    is_warning_exist = true if is_read_trackrecord_warning
  else
    raise <<-MSG
#{load_config_file} に設定された#{RECORD_SW_NAME}データベースファイルが見つかりません。
・#{PROGRAM_NAME}のインストール場所が正しいかどうか、確認してください
　デフォルト設定の場合、#{RECORD_SW_NAME}フォルダに、#{PROGRAM_NAME}をフォルダごとおいてください。
・#{load_config_file} を変更した場合、設定が正しいかどうか、確認してください
    MSG
  end

  puts

  ## 報告対象データの送信処理

  # 報告対象データが0件なら送信しない
  if trackrecords.length == 0 then
    puts "報告対象データはありませんでした。"
  else

    # 対戦結果データを分割して送信
    0.step(trackrecords.length, TRACKRECORD_POST_SIZE) do |start_row_num|
      end_row_num = [start_row_num + TRACKRECORD_POST_SIZE - 1, trackrecords.length - 1].min
      response = nil # サーバーからのレスポンスデータ

      puts "#{trackrecords.length}件中の#{start_row_num + 1}件目～#{end_row_num + 1}件目を送信しています#{is_force_insert ? "（強制インサートモード）" : ""}...\n"

      # 送信用XML生成
      trackrecord_xml_string = trackrecord2xml_string(game_id, account_name, account_password, trackrecords[start_row_num..end_row_num], is_force_insert)      
      # デバッグ用保存
      File.open('./last_report_trackrecord.xml', 'wb') { |io| io.write trackrecord_xml_string }

      # データ送信
      Net::HTTP.new(SERVER_TRACK_RECORD_HOST, 80).start do |s|
        response = s.post(SERVER_TRACK_RECORD_PATH, trackrecord_xml_string, HTTP_REQUEST_HEADER)
      end

      # 送信結果表示
      puts "サーバーからのお返事"
      response.body.each_line do |line|
        puts "> #{line}"
      end
      puts

      if response.code == '200' then
        sleep 1
      else
        if response.body.index(PLEASE_RETRY_FORCE_INSERT)
          puts "強制インサートモードで報告しなおします。5秒後に報告再開...\n\n"
          sleep 5
          is_force_insert = true
          redo
        else
          raise "報告時にサーバー側でエラーが発生しました。処理を中断します。"
        end
      end
    end
  end
  
  ## リプレイファイル送信
  if trackrecords.length != 0  then
    puts "★リプレイファイル送信"
    if !is_send_replay then
      puts "リプレイファイル送信をしない設定のためスキップします。"
    else  
      unless File.file?(replay_config_path) then
        puts "！#{replay_config_path} が見つかりません。リプレイファイル送信をスキップします。"
        is_warning_exist = true
      else

        def send_replay(replay_files, game_id, account_name, account_password)
          replay_files.each do |replay_file|
            print "送信リプレイファイル: "
            puts "#{replay_file[:path]}"
            trackrecord = replay_file[:trackrecord]
            replay_path = replay_file[:path]
            http_multipart_data = {}
            
            puts "送信データ作成・リプレイファイル暗号化..."
            
            # 送信データ作成
            replay_posting_xml = make_replay_posting_xml(trackrecord, game_id, account_name, account_password)
            http_multipart_data[:meta_info] = replay_posting_xml
            http_multipart_data[:replay_file] = mask_replay_data(File.open(replay_path, "rb") { |io| io.read })
            
            # HTTP Multipart 用のリクエストボディ・リクエストヘッダ取得
            request_data = make_http_multipart_data(http_multipart_data)
            request_body = request_data[:body]
            request_header = HTTP_REQUEST_HEADER.merge(request_data[:header])
            
            # デバッグ用保存
            File.open("last_replay_body.dat","wb") { |io| io.write request_body }
            
            # データ送信
            puts "サーバーにリプレイファイルを送信..."
            response = nil
            Net::HTTP.new(SERVER_REPLAY_UPLOAD_HOST, 80).start do |s|
              response = s.post(SERVER_REPLAY_UPLOAD_PATH, request_body, request_header)
            end

            # 送信結果表示
            puts "サーバーからのお返事"
            response.body.each_line do |line|
              puts "> #{line}"
            end
            puts
            
          end
          
        end
        
        replay_files = get_replay_files(trackrecords, replay_config_path, send_replay_file_num)
        if replay_files.length > 0 then
          send_replay(replay_files, game_id, account_name, account_password)
        else
          puts "リプレイファイルが見つけられませんでした。"
        end
      end
    end
  
  end

  # 設定ファイル更新
  save_config(save_config_file, config)

  puts

  # 終了メッセージ出力
  if is_warning_exist then
    puts "報告処理は正常に終了しましたが、警告メッセージがあります。"
    puts "出力結果をご確認ください。"
    puts
    puts "Enter キーを押すと、処理を終了します。"
    exit if gets
    puts
  else
    puts "報告処理が正常に終了しました。"
  end

  sleep 3

### 全体エラー処理 ###
rescue => ex
  if config && config['account'] then
    config['account']['name']     = '<secret>' if config['account']['name']
    config['account']['password'] = '<secret>' if config['account']['password']
  end

  puts
  puts "処理中にエラーが発生しました。処理を中断します。\n"
  puts
  puts '### エラー詳細ここから ###'
  puts
  puts ex.to_s
  puts
  puts ex.backtrace.join("\n")
  puts (config ? config.to_yaml : "config が設定されていません。")
  if response then
    puts
    puts "<サーバーからの最後のメッセージ>"
    puts "HTTP status code : #{response.code}"
    puts response.body
  end
  puts
  puts '### エラー詳細ここまで ###'

  # エラーログ出力
  File.open(ERROR_LOG_PATH, 'a') do |log|
    log.puts "#{Time.now.strftime('%Y/%m/%d %H:%M:%S')} #{File::basename(__FILE__)} #{PROGRAM_VERSION}"
    log.puts ex.to_s
    log.puts ex.backtrace.join("\n")
    log.puts config ? config.to_yaml : "config が設定されていません。"
    if response then
      log.puts "<サーバーからの最後のメッセージ>"
      log.puts "HTTP status code : #{response.code}"
      log.puts response.body
    end
    log.puts '********'
  end

  puts
  puts "上記のエラー内容を #{ERROR_LOG_PATH} に書き出しました。"
  puts

  puts "Enter キーを押すと、処理を終了します。"
  exit if gets
end
