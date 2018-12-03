@rem uru 187
@rem pik use 187
@rem set PATH=C:\ruby187\bin;%PATH%

@set client_name=tsk_report

start /wait mkexy %client_name%.rb
type %client_name%.exy.icon.txt >> %client_name%.exy

@set upx_exe=C:\Program files_free\Free_UPX\upx.exe
@set /P ver="Input Release Version:"
@set time_tmp=%time: =0%
@set now=%date:/=%_%time_tmp:~0,2%%time_tmp:~3,2%%time_tmp:~6,2%
@set output_dir=bin\%client_name%_v%ver%_%now%

mkdir "%output_dir%"
mkdir "%output_dir%\src"

@for %%i in (
  config_default.yaml
  env.yaml
  readme.txt
  history.txt
  ëSåèïÒçêÉÇÅ[Éh.bat
  dependencies\*
) do @echo %%i & @copy %%i "%output_dir%"

@for %%i in (
  make_exe.bat
  %client_name%.exy.icon.txt
  suwako.ico
  %client_name%.rb
) do @echo src\%%i & @copy %%i %output_dir%\src

@echo D | @xcopy /S lib "%output_dir%\src\lib"

start /wait cmd /c exerb %client_name%.exy -o "%output_dir%\%client_name%.exe"
"%upx_exe%" "%output_dir%\%client_name%.exe"
