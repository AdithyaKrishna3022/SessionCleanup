$Bucket = 'iwd-aws-clickops-installers-and-executables'
$Profile = 'appstream_machine_role'
New-Item -ItemType Directory -Path C:\Temp\Installers -Force | Out-Null

& {
  Write-Host "--- 1. Keys containing 'redist' (case-insensitive) ---"
  aws s3api list-objects-v2 --bucket $Bucket --prefix "Golden Image/" --query "Contents[?contains(to_string(Key),'edist')].[Key,Size]" --output json --profile $Profile

  Write-Host "--- 2. Download with full output ---"
  aws s3 cp "s3://$Bucket/Golden Image/" C:\Temp\Installers --recursive --exclude "*" --include "*edist*" --profile $Profile

  Write-Host "--- 3. Files now in C:\Temp\Installers ---"
  Get-ChildItem C:\Temp\Installers -Recurse | Select-Object FullName, Length | Format-Table -AutoSize | Out-String -Width 200
} *>&1 | Tee-Object -FilePath C:\Temp\diag-s3.txt
