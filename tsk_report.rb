# -*- coding: utf-8 -*-
require 'rubygems'
require 'sqlite3'
require 'kconv'
require 'nkf'
require 'net/http'
Net::HTTP.version_1_2 
require 'rexml/document'
require 'yaml'
require 'time'
require 'digest/sha1'
require 'optparse'

# プログラム情報
PROGRAM_VERSION = '0.03a'
PROGRAM_NAME = '天則観報告ツール'

# 設定
TRACKRECORD_POST_SIZE = 250   # 一度に送信する対戦結果数
DUPLICATION_LIMIT_TIME_SECONDS = 2   # タイムスタンプが何秒以内のデータを、重複データとみなすか
ACCOUNT_NAME_REGEX = /\A[a-zA-Z0-9_]{1,32}\z/
MAIL_ADDRESS_REGEX = /\A[\x01-\x7F]+@(([-a-z0-9]+\.)*[a-z]+|\[\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\])\z/ # メールアドレスチェック用正規表現
PLEASE_RETRY_FORCE_INSERT = "<Please Retry in Force-Insert Mode>"  # 強制インサートリトライのお願い文字列
HTTP_REQUEST_HEADER = {"User-Agent" => "Tensokukan Report Tool #{PROGRAM_VERSION}"}
RECORD_SW_NAME = '天則観' # 対戦記録ソフトウェア名
DB_TR_TABLE_NAME = 'trackrecord123' # DBの対戦結果テーブル名
WEB_SERVICE_NAME = 'Tenco!'  # サーバ側のサービス名

# デフォルト値
DEFAULT_GAME_ID = 2    # ゲームID
DEFAULT_DATABASE_FILE_PATH = '../*.db' # データベースファイルパス

# ログファイルパス
ERROR_LOG_PATH = 'error.txt'

# 送信設定
is_force_insert = false # 強制インサートモード。はじめは false。
is_all_report = false # 全件報告モード。サーバーからの最終対戦時刻をとらず、全件送信。

# 変数
trackrecord = [] # 対戦結果
is_warning_exist = false # 警告メッセージがあるかどうか

print "*** #{PROGRAM_NAME} *** ver.#{PROGRAM_VERSION}\n\n".kconv(Kconv::SJIS, Kconv::UTF8)

begin

### 設定読み込み ###

# 設定ファイルパス
config_file = 'config.yaml'
config_default_file = 'config_default.yaml'
env_file = 'env.yaml'

# 設定ファイルがなければデフォルトをコピーして作成
unless File.exist?(config_file) then
	open(config_default_file) do |s|
		open(config_file, "w") do |d|
			d.write(s.read)
		end
	end
end

# サーバー環境設定ファイルがなければ、エラー終了
unless File.exist?(env_file) then
	raise "#{env_file} が見つかりません。\nダウンロードした本プログラムのフォルダからコピーしてください。"
end

# 設定ファイル読み込み
# UTF-8 対応のため、一旦 Kconv を通して UTF-8N にする。
config = YAML.load(File.read(config_file).kconv(Kconv::UTF8, Kconv::UTF8))
env = YAML.load(File.read(env_file).kconv(Kconv::UTF8, Kconv::UTF8))

# config.yaml がおかしいと代入時にエラーが出ることに対する格好悪い対策
config ||= {}
config['account'] ||= {}
config['database'] ||= {}

account_name = config['account']['name'].to_s || ''
account_password = config['account']['password'].to_s || ''
# ゲームIDを設定ファイルから読み込む機能は -g オプションが必要
game_id = DEFAULT_GAME_ID
db_file_path = config['database']['file_path'].to_s || DEFAULT_DATABASE_FILE_PATH

# proxy_host = config['proxy']['host']
# proxy_port = config['proxy']['port']
# last_report_time = config['last_report_time']
# IS_USE_HTTPS = false

SERVER_TRACK_RECORD_HOST = env['server']['track_record']['host'].to_s
SERVER_TRACK_RECORD_PATH = env['server']['track_record']['path'].to_s
SERVER_LAST_TRACK_RECORD_HOST = env['server']['last_track_record']['host'].to_s
SERVER_LAST_TRACK_RECORD_PATH = env['server']['last_track_record']['path'].to_s
SERVER_ACCOUNT_HOST = env['server']['account']['host'].to_s
SERVER_ACCOUNT_PATH = env['server']['account']['path'].to_s

### メソッド定義 ###

# 試合結果データ読み込み
# 発生時間が古い順にデータを並べて返す
# 指定されたデータベースファイルが存在しなければ、例外を発生させる
# db_file 名は cp932 で渡すこと
def read_trackrecord(db_file_cp932, last_report_filetime = 0)
	trackrecord = []
	db_file_utf8 = NKF.nkf('-Sw --cp932', db_file_cp932)
	
	# DB接続
	# DBファイルがなければ例外発生
	raise <<-MSG unless File.exist?(db_file_cp932)
#{RECORD_SW_NAME}データベースファイルが見つかりません。(パス：#{db_file_utf8})
・エクスプローラー上で見て、もし該当パス名のファイルがあり、サイズが0KBであれば、削除してください
　一部の特殊な文字を含むDBファイル名は、正常に読み込みができないかもしれません。
　ファイル名を変更することで解決する可能性があります。
#{ex.to_s}
#{ex.backtrace.join("\n")}
	MSG

	# DBファイルサイズが0なら処理スキップ
	if File.size?(db_file_cp932) == 0
		puts "！ファイルサイズが 0KB です(パス：#{db_file_utf8})。処理をスキップします。".kconv(Kconv::SJIS, Kconv::UTF8)
		return trackrecord
	end
	
	begin
		begin
			db = SQLite3::Database.open(db_file_utf8)
			# SQLite3 モジュールの UTF16 ファイル名対応をONにした場合の読み込み
			# ただ、UTF16対応の必要なファイル名だと、テーブル名が見つからないなど、データが読めないことがある。理由は謎。
			# require 'nkf'
			# db = SQLite3::Database.open(NKF.nkf('-S -w16' ,db_file), {:utf16 => true})
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
				    timestamp > #{last_report_filetime.to_i}
				AND	COALESCE(p1name, '') != ''
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
	trackrecord.sort! {|a, b| Time.parse(a['timestamp']) <=> Time.parse(b['timestamp'])}

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
		puts "#{delete_trackrecord.length} 件のデータは、重複データと疑われるため報告されません。".kconv(Kconv::SJIS, Kconv::UTF8)
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

# UTF8文字列をデコード
# YAML(Syck) の to_yaml が日本語対応してない対策
def decode(string)
	string.gsub(/\\x(\w{2})/){[Regexp.last_match.captures.first.to_i(16)].pack("C")}
end

# コンフィグファイル保存
def save_config(config_file, config)
	File.open(config_file, 'w') do |w|
		w.puts "# #{PROGRAM_NAME}設定ファイル"
		w.puts "# かならず文字コードは UTF-8 または UTF-8N で保存してください。"
		w.puts "# メモ帳でも編集・保存できます。"
		w.puts decode(config.to_yaml)
	end
end

### メイン処理 ###

## オプション設定
opt = OptionParser.new

opt.on('-a') {|v| is_all_report = true} # 全件報告モード

# 設定ファイルのゲームID設定を有効にする
opt.on('-g') do |v|
	begin
		game_id = config['game']['id'].to_i
	rescue => ex
		raise "エラー：設定ファイル（#{config_file}）から、ゲームIDを取得できませんでした。"
	end
	
	if game_id.nil? || game_id < 1 then
		raise "エラー：設定ファイル（#{config_file}）のゲームIDの記述が正しくありません。"
	end
	
	puts "★設定ファイルのゲームID（#{game_id}）で報告を実行します".kconv(Kconv::SJIS, Kconv::UTF8)
end

opt.on('--database-filepath-default-overwrite') do |v|  # 設定ファイルのデータベースファイルパスをデフォルトにする
	puts "★設定ファイルの#{RECORD_SW_NAME}DBファイルパスを上書きします".kconv(Kconv::SJIS, Kconv::UTF8)
	puts "#{config_file} の#{RECORD_SW_NAME}DBファイルパスを #{DEFAULT_DATABASE_FILE_PATH} に書き換え...".kconv(Kconv::SJIS, Kconv::UTF8)
	config['database']['file_path'] = DEFAULT_DATABASE_FILE_PATH
	save_config(config_file, config)
	puts "設定ファイルを保存しました！".kconv(Kconv::SJIS, Kconv::UTF8)
	puts
	exit
end

opt.parse!(ARGV)

## アカウント設定（新規アカウント登録／既存アカウント設定）処理
unless (account_name && account_name =~ ACCOUNT_NAME_REGEX) then
	is_new_account = nil
	account_name = ''
	account_password = ''
	is_account_register_finish = false
	
	puts "★#{WEB_SERVICE_NAME} アカウント設定（初回実行時）\n".kconv(Kconv::SJIS, Kconv::UTF8)
	puts "#{WEB_SERVICE_NAME} をはじめてご利用の場合、「1」をいれて Enter キーを押してください。".kconv(Kconv::SJIS, Kconv::UTF8)
	puts "すでに緋行跡報告ツール等でアカウント登録済みの場合、「2」をいれて Enter キーを押してください。\n".kconv(Kconv::SJIS, Kconv::UTF8)
	puts
	print "> "
	
	while (input = gets)
		input.strip!
		if input == "1"
			is_new_account = true
			puts
			break
		elsif input == "2"
			is_new_account = false
			puts
			break
		end
		puts 
	puts "#{WEB_SERVICE_NAME} をはじめてご利用の場合、「1」をいれて Enter キーを押してください。".kconv(Kconv::SJIS, Kconv::UTF8)
	puts "すでに緋行跡報告ツール等で #{WEB_SERVICE_NAME} アカウントを登録済みの場合、「2」をいれて Enter キーを押してください。\n".kconv(Kconv::SJIS, Kconv::UTF8)
		puts
		print "> "
	end
	
	if (is_new_account) then
		
		puts "★新規 #{WEB_SERVICE_NAME} アカウント登録\n\n".kconv(Kconv::SJIS, Kconv::UTF8)
		
		while (!is_account_register_finish)
			# アカウント名入力
			puts "希望アカウント名を入力してください\n".kconv(Kconv::SJIS, Kconv::UTF8)
			puts "アカウント名はURLの一部として使用されます。\n".kconv(Kconv::SJIS, Kconv::UTF8)
			puts "（半角英数とアンダースコア_のみ使用可能。32文字以内）\n".kconv(Kconv::SJIS, Kconv::UTF8)
			print "希望アカウント名> ".kconv(Kconv::SJIS, Kconv::UTF8)
			while (input = gets)
				input.strip!
				if input =~ ACCOUNT_NAME_REGEX then
					account_name = input
					puts 
					break
				else
					puts "！希望アカウント名は半角英数とアンダースコア_のみで、32文字以内で入力してください".kconv(Kconv::SJIS, Kconv::UTF8)
					print "希望アカウント名> ".kconv(Kconv::SJIS, Kconv::UTF8)
				end
			end
			
			# パスワード入力
			puts "パスワードを入力してください（使用文字制限なし。4～16byte以内。アカウント名と同一禁止。）\n".kconv(Kconv::SJIS, Kconv::UTF8)
			print "パスワード> ".kconv(Kconv::SJIS, Kconv::UTF8)
			while (input = gets)
				input.strip!
				if (input.length >= 4 and input.length <= 16 and input != account_name) then
					account_password = input
					break
				else
					puts "！パスワードは4～16byte以内で、アカウント名と別の文字列を入力してください".kconv(Kconv::SJIS, Kconv::UTF8)
					print "パスワード> ".kconv(Kconv::SJIS, Kconv::UTF8)
				end
			end 
			
			print "パスワード（確認）> ".kconv(Kconv::SJIS, Kconv::UTF8)
			while (input = gets)
				input.strip!
				if (account_password == input) then
					puts 
					break
				else
					puts "！パスワードが一致しません\n".kconv(Kconv::SJIS, Kconv::UTF8)
					print "パスワード（確認）> ".kconv(Kconv::SJIS, Kconv::UTF8)
				end
			end
			
			# メールアドレス入力
			puts "メールアドレスを入力してください（入力は任意）\n".kconv(Kconv::SJIS, Kconv::UTF8)
			puts "※パスワードを忘れたときの連絡用にのみ使用します。\n".kconv(Kconv::SJIS, Kconv::UTF8)
			puts "※記入しない場合、パスワードの連絡はできません。\n".kconv(Kconv::SJIS, Kconv::UTF8)
			print "メールアドレス> ".kconv(Kconv::SJIS, Kconv::UTF8)
			while (input = gets)
				input.strip!
				if (input == '') then
					account_mail_address = ''
					puts "メールアドレスは登録しません。".kconv(Kconv::SJIS, Kconv::UTF8)
					puts
					break
				elsif input =~ MAIL_ADDRESS_REGEX and input.length <= 256 then
					account_mail_address = input
					puts
					break
				else
					puts "！メールアドレスは正しい形式で、256byte以内にて入力してください".kconv(Kconv::SJIS, Kconv::UTF8)
					print "メールアドレス> ".kconv(Kconv::SJIS, Kconv::UTF8)
				end
			end
			
			# 新規アカウントをサーバーに登録
			puts "サーバーにアカウントを登録しています...\n".kconv(Kconv::SJIS, Kconv::UTF8)
			
			# アカウント XML 生成
			account_xml = REXML::Document.new
			account_xml << REXML::XMLDecl.new('1.0', 'UTF-8')
			account_element = account_xml.add_element("account")
			account_element.add_element('name').add_text(account_name)
			account_element.add_element('password').add_text(account_password)
			account_element.add_element('mail_address').add_text(account_mail_address)
			# サーバーに送信
			response = nil
			# http = Net::HTTP.new(SERVER_ACCOUNT_HOST, 443)
			# http.use_ssl = true
			# http.verify_mode = OpenSSL::SSL::VERIFY_NONE
			http = Net::HTTP.new(SERVER_ACCOUNT_HOST, 80)
			http.start do |s|
				response = s.post(SERVER_ACCOUNT_PATH, account_xml.to_s, HTTP_REQUEST_HEADER)
			end
			
			print "サーバーからのお返事\n".kconv(Kconv::SJIS, Kconv::UTF8)
			response.body.each_line do |line|
				puts "> #{line.kconv(Kconv::SJIS, Kconv::UTF8)}"
			end

			if response.code == '200' then
			# アカウント登録成功時
				is_account_register_finish = true
				config['account']['name'] = account_name
				config['account']['password'] = account_password
				
				save_config(config_file, config)
				
				puts 
				puts "アカウント情報を設定ファイルに保存しました。".kconv(Kconv::SJIS, Kconv::UTF8)
				puts "サーバーからのお返事の内容をご確認ください。".kconv(Kconv::SJIS, Kconv::UTF8)
				puts
				puts "Enter キーを押すと、続いて対戦結果の報告をします...".kconv(Kconv::SJIS, Kconv::UTF8)
				gets
				puts "引き続き、対戦結果の報告をします...".kconv(Kconv::SJIS, Kconv::UTF8)
				puts
			else
			# アカウント登録失敗時
				puts "もう一度アカウント登録をやり直します...\n\n".kconv(Kconv::SJIS, Kconv::UTF8)
				sleep 1
			end
			
		end # while (!is_account_register_finish)
	else

		puts "★設定ファイル編集\n".kconv(Kconv::SJIS, Kconv::UTF8)
		puts "#{WEB_SERVICE_NAME} アカウント名とパスワードを設定します".kconv(Kconv::SJIS, Kconv::UTF8)
		puts "※アカウント名とパスワードが分からない場合、ご利用の#{WEB_SERVICE_NAME}クライアント（緋行跡報告ツール等）の#{config_file}で確認できます".kconv(Kconv::SJIS, Kconv::UTF8)
		puts 
		puts "お持ちの #{WEB_SERVICE_NAME} アカウント名を入力してください".kconv(Kconv::SJIS, Kconv::UTF8)
		
		# アカウント名入力
		print "アカウント名> ".kconv(Kconv::SJIS, Kconv::UTF8)
		while (input = gets)
			input.strip!
			if input =~ ACCOUNT_NAME_REGEX then
				account_name = input
				puts 
				break
			else
				puts "！アカウント名は半角英数とアンダースコア_のみで、32文字以内で入力してください".kconv(Kconv::SJIS, Kconv::UTF8)
			end
			print "アカウント名> ".kconv(Kconv::SJIS, Kconv::UTF8)
		end
		
		# パスワード入力
		puts "パスワードを入力してください\n".kconv(Kconv::SJIS, Kconv::UTF8)
		print "パスワード> ".kconv(Kconv::SJIS, Kconv::UTF8)
		while (input = gets)
			input.strip!
			if (input.length >= 4 and input.length <= 16 and input != account_name) then
				account_password = input
				puts
				break
			else
				puts "！パスワードは4～16byte以内で、アカウント名と別の文字列を入力してください".kconv(Kconv::SJIS, Kconv::UTF8)
				puts "パスワード：".kconv(Kconv::SJIS, Kconv::UTF8)
			end
			print "パスワード> ".kconv(Kconv::SJIS, Kconv::UTF8)
		end
		
		# 設定ファイル保存
		config['account']['name'] = account_name
		config['account']['password'] = account_password
		save_config(config_file, config)
		
		puts "アカウント情報を設定ファイルに保存しました。\n\n".kconv(Kconv::SJIS, Kconv::UTF8)
		puts "引き続き、対戦結果の報告をします...\n\n".kconv(Kconv::SJIS, Kconv::UTF8)
		
	end # if is_new_account
	
	sleep 2

end

	
## 登録済みの最終対戦結果時刻を取得する
unless is_all_report then
	puts "★登録済みの最終対戦時刻を取得".kconv(Kconv::SJIS, Kconv::UTF8)
	puts "GET http://#{SERVER_LAST_TRACK_RECORD_HOST}#{SERVER_LAST_TRACK_RECORD_PATH}?game_id=#{game_id}&account_name=#{account_name}"

	http = Net::HTTP.new(SERVER_LAST_TRACK_RECORD_HOST, 80)
	response = nil
	http.start do |s|
		response = s.get("#{SERVER_LAST_TRACK_RECORD_PATH}?game_id=#{game_id}&account_name=#{account_name}", HTTP_REQUEST_HEADER)
	end

	if response.code == '200' or response.code == '204' then
		if (response.body and response.body != '') then
			last_report_time = Time.parse(response.body)
			puts "サーバー登録済みの最終対戦時刻：#{last_report_time.strftime('%Y/%m/%d %H:%M:%S')}".kconv(Kconv::SJIS, Kconv::UTF8)
		else
			last_report_time = Time.at(0)
			puts "サーバーには対戦結果未登録です".kconv(Kconv::SJIS, Kconv::UTF8)
		end
	else
		raise "最終対戦時刻の取得時にサーバーエラーが発生しました。処理を中断します。"
	end
else
	puts "★全件報告モードです。サーバーからの登録済み最終対戦時刻の取得をスキップします。".kconv(Kconv::SJIS, Kconv::UTF8)
	last_report_time = Time.at(0)
end
puts

## 対戦結果報告処理
puts "★対戦結果送信".kconv(Kconv::SJIS, Kconv::UTF8)
puts ("#{RECORD_SW_NAME}の記録から、" + last_report_time.strftime('%Y/%m/%d %H:%M:%S') + " 以降の対戦結果を報告します。").kconv(Kconv::SJIS, Kconv::UTF8)
puts

# DBから対戦結果を取得
db_files = Dir::glob(NKF.nkf('-Ws --cp932', db_file_path))

if db_files.length > 0
	db_files.each do |db_file|
		puts "#{NKF.nkf('-Sw --cp932', db_file)} から対戦結果を抽出...\n".kconv(Kconv::SJIS, Kconv::UTF8)
		begin
			trackrecord.concat(read_trackrecord(db_file, time_to_filetime(last_report_time + 1)))
		rescue => ex
			is_warning_exist = true
			puts "！警告".kconv(Kconv::SJIS, Kconv::UTF8)
			puts ex.to_s.kconv(Kconv::SJIS, Kconv::UTF8)
			puts "処理を続行します...".kconv(Kconv::SJIS, Kconv::UTF8)
			puts
		end
	end
else
	raise <<-MSG
#{config_file} に設定された#{RECORD_SW_NAME}データベースファイルが見つかりません。
・#{PROGRAM_NAME}のインストール場所が正しいかどうか、確認してください
　デフォルト設定の場合、#{RECORD_SW_NAME}フォルダに、#{PROGRAM_NAME}をフォルダごとおいてください。
・#{config_file} を変更した場合、設定が正しいかどうか、確認してください
	MSG
end

puts

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
	t['p1name'] = t['p1name'].kconv(Kconv::UTF8, Kconv::SJIS)
	t['p2name'] = t['p2name'].kconv(Kconv::UTF8, Kconv::SJIS)
end

## 報告対象データの送信処理

# 報告対象データが0件なら送信しない
if trackrecord.length <= 0 then
	puts "報告対象データはありませんでした。".kconv(Kconv::SJIS, Kconv::UTF8)
else
	
	# 対戦結果データを分割して送信
	0.step(trackrecord.length, TRACKRECORD_POST_SIZE) do |start_row_num|
		end_row_num = [start_row_num + TRACKRECORD_POST_SIZE - 1, trackrecord.length - 1].min
		response = nil # サーバーからのレスポンスデータ
		
		puts "#{trackrecord.length}件中の#{start_row_num + 1}件目～#{end_row_num + 1}件目を送信しています#{is_force_insert ? "（強制インサートモード）" : ""}...\n".kconv(Kconv::SJIS, Kconv::UTF8)
		
		# 送信用XML生成
		trackrecord_xml_string = trackrecord2xml_string(game_id, account_name, account_password, trackrecord[start_row_num..end_row_num], is_force_insert)
		File.open('./last_report_trackrecord.xml', 'w') do |w|
			w.puts trackrecord_xml_string
		end

		# データ送信
		# https = Net::HTTP.new(SERVER_TRACK_RECORD_HOST, 443)
		# https.use_ssl = true
		# https.verify_mode = OpenSSL::SSL::VERIFY_NONE
		# https = Net::HTTP::Proxy(proxy_addr, proxy_port).new(SERVER_TRACK_RECORD_HOST,443)
		# https.ca_file = '/usr/share/ssl/cert.pem'
		# https.verify_depth = 5
		# https.verify_mode = OpenSSL::SSL::VERIFY_PEER
		http = Net::HTTP.new(SERVER_TRACK_RECORD_HOST, 80)
		http.start do |s|
			response = s.post(SERVER_TRACK_RECORD_PATH, trackrecord_xml_string, HTTP_REQUEST_HEADER)
		end
		
		# 送信結果表示
		puts "サーバーからのお返事".kconv(Kconv::SJIS, Kconv::UTF8)
		response.body.each_line do |line|
			puts "> #{line.kconv(Kconv::SJIS, Kconv::UTF8)}"
		end
		puts
		
		if response.code == '200' then
			sleep 1
			# 特に表示しない
		else
			if response.body.index(PLEASE_RETRY_FORCE_INSERT)
				puts "強制インサートモードで報告しなおします。5秒後に報告再開...\n\n".kconv(Kconv::SJIS, Kconv::UTF8)
				sleep 5
				is_force_insert = true
				redo
			else
				raise "報告時にサーバー側でエラーが発生しました。処理を中断します。"
			end
		end
	end
end

# 設定ファイル更新
save_config(config_file, config)
		
puts

# 終了メッセージ出力
if is_warning_exist then
	puts "報告処理は正常に終了しましたが、警告メッセージがあります。".kconv(Kconv::SJIS, Kconv::UTF8)
	puts "出力結果をご確認ください。".kconv(Kconv::SJIS, Kconv::UTF8)
	puts
	puts "Enter キーを押すと、処理を終了します。".kconv(Kconv::SJIS, Kconv::UTF8)
	exit if gets
	puts
else
	puts "報告処理が正常に終了しました。".kconv(Kconv::SJIS, Kconv::UTF8)
end

sleep 3

### 全体エラー処理 ###
rescue => ex
	if config && config['account'] then
		config['account']['name']     = '<secret>' if config['account']['name']
		config['account']['password'] = '<secret>' if config['account']['password']
	end
	
	puts 
	puts "処理中にエラーが発生しました。処理を中断します。\n".kconv(Kconv::SJIS, Kconv::UTF8)
	puts 
	puts '### エラー詳細ここから ###'.kconv(Kconv::SJIS, Kconv::UTF8)
	puts
	puts ex.to_s.kconv(Kconv::SJIS, Kconv::UTF8)
	puts
	puts ex.backtrace.join("\n").kconv(Kconv::SJIS, Kconv::UTF8)
	puts (config ? decode(config.to_yaml) : "config が設定されていません。").kconv(Kconv::SJIS, Kconv::UTF8)
	if response then
		puts
		puts "<サーバーからの最後のメッセージ>".kconv(Kconv::SJIS, Kconv::UTF8)
		puts "HTTP status code : #{response.code}"
		puts response.body.kconv(Kconv::SJIS, Kconv::UTF8)
	end
	puts
	puts '### エラー詳細ここまで ###'.kconv(Kconv::SJIS, Kconv::UTF8)
	
	File.open(ERROR_LOG_PATH, 'a') do |log|
		log.puts "#{Time.now.strftime('%Y/%m/%d %H:%M:%S')} #{File::basename(__FILE__)} #{PROGRAM_VERSION}" 
		log.puts ex.to_s
		log.puts ex.backtrace.join("\n")
		log.puts config ? decode(config.to_yaml) : "config が設定されていません。"
		if response then
			log.puts "<サーバーからの最後のメッセージ>"
			log.puts "HTTP status code : #{response.code}"
			log.puts response.body
		end
		log.puts '********'
	end
	
	puts
	puts "上記のエラー内容を #{ERROR_LOG_PATH} に書き出しました。".kconv(Kconv::SJIS, Kconv::UTF8)
	puts
	
	puts "Enter キーを押すと、処理を終了します。".kconv(Kconv::SJIS, Kconv::UTF8)
	exit if gets
end
