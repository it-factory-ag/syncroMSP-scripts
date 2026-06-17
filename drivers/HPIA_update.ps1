# https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html
$url = 'https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-5.3.6.exe'

$dir = 'C:\_admin\HPIA'
$swsetup = 'C:\_admin\HPIA\SWSETUP'
$file = "C:\_admin\HPIA\hpia.exe"
$folder = "c:\_admin\HPIA\inst"

mkdir $dir
mkdir $folder
mkdir $swsetup
Remove-Item $file
Remove-Item $folder -Recurse
$webClient = New-Object System.Net.WebClient
$webClient.DownloadFile($url,$file)

Start-Process -FilePath $file -ArgumentList '/s /e /f c:\_admin\HPIA\inst'
Start-Sleep -s 10
Start-Process -wait -FilePath "c:\_admin\HPIA\inst\HPImageAssistant.exe" -ArgumentList '/Operation:Analyze /Category:All /Selection:All /Action:Install /SoftpaqDownloadFolder:c:\_admin\HPIA\SWSETUP /Silent /AutoCleanup'

Start-Sleep -s 10
Remove-Item $file
Remove-Item $folderold -Recurse
Remove-Item $folder -Recurse
