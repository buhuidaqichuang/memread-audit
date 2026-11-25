# dummies.ps1 - 列出身边所有疑似靶子(假人)坐标; 地形无关版
#
# 模式1 扫描:   .\dummies.ps1 -x 1496 -y -8697 -r 400 -FeetZ 5.10
# 模式2 存档:   .\dummies.ps1 -x 1496 -y -8697 -r 400 -FeetZ 5.10 -Save C:\Temp\targets.csv
# 模式3 对比:   .\dummies.ps1 -Diff C:\Temp\targets.csv      # 打倒靶子后跑, 清零的就是靶子
#
# 判据(全部相对化, 复杂地形也成立):
#   1) 份数 n <= 3                    靶子只有 1~2 份坐标
#   2) z - 自己脚底 z 落在 95..140     躯干高度, 随地面起伏自适应
#   3) 相对高度差不在 86±1 / >=145    排除自己的腰层(脚底+86)与相机层(脚底+150)
#   4) 邻域 30 单位内同类点 < 5        自己的姿态副本永远成串(每 7~10 单位一个样本), 靶子是孤立点

param(
  [string]$Dev = 'root@192.168.3.193',
  [string]$Key = 'C:\Users\gsy\AppData\Local\Temp\memread_ssh',
  [string]$Proc = 'DeltaForce',
  [double]$x = 0,
  [double]$y = 0,
  [int]$r = 400,
  [int]$topN = 400,
  [double]$FeetZ = 5.10,
  [string]$FeetAddr = '',
  [string]$LocalFile = '',
  [string]$Save = '',
  [string]$Diff = ''
)

$ErrorActionPreference = 'Stop'

function Invoke-Ssh([string]$cmd) {
  $f = Join-Path $env:TEMP 'dssh.txt'
  & ssh -i $Key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $Dev $cmd *> $f
  return ((Get-Content -LiteralPath $f -Encoding UTF8) -join "`n")
}

function Invoke-Read([string]$addr) {
  $txt = Invoke-Ssh "/var/tmp/memread read $Proc $addr"
  if ($txt -match 'vec3=\((-?[\d\.\-]+),\s*(-?[\d\.\-]+),\s*(-?[\d\.\-]+)\)') {
    return ,@([double]$Matches[1], [double]$Matches[2], [double]$Matches[3])
  }
  return ,@([double]::NaN, [double]::NaN, [double]::NaN)
}

# ============ 模式3: 对比 ============
if ($Diff -ne '') {
  $rows = Import-Csv -LiteralPath $Diff -Encoding UTF8
  "对比 $($rows.Count) 个候选地址（打倒靶子后应只有靶子清零）"
  ""
  "  {0,-12} {1,8}  {2,22}  {3,6}  {4}" -f '状态','距离m','坐标','Z','地址'
  foreach ($c in $rows) {
    $v = Invoke-Read $c.addr
    $zero = ([math]::Abs($v[0]) -lt 1e-6 -and [math]::Abs($v[1]) -lt 1e-6 -and [math]::Abs($v[2]) -lt 1e-6)
    $st = if ($zero) { '清零=靶子' } else { '未变' }
    "  {0,-12} {1,7:N2}  ({2,9:N2},{3,9:N2})  {4,6:N2}  {5}" -f $st, ([double]$c.d / 100.0), [double]$c.x, [double]$c.y, [double]$c.z, $c.addr
  }
  return
}

# ============ 取自己脚底 Z (地形复杂时一定要给, 否则判据偏移) ============
if ($FeetAddr -ne '') {
  $fv = Invoke-Read $FeetAddr
  if (-not [double]::IsNaN($fv[2])) { $FeetZ = $fv[2]; "自己脚底 Z = $FeetZ (来自 $FeetAddr)" }
}

# ============ 模式1/2: 扫描 ============
if ($LocalFile -ne '') {
  $lines = Get-Content -LiteralPath $LocalFile -Encoding UTF8
} else {
  $devFile = '/var/tmp/dscan.txt'
  $local = Join-Path $env:TEMP 'dscan_local.txt'
  Invoke-Ssh "MEMREAD_LOOSE=1 /var/tmp/memread clusterq $Proc $x $y $r 1 $topN > $devFile 2>&1; echo ok" | Out-Null
  & scp -i $Key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${Dev}:$devFile" $local *> (Join-Path $env:TEMP 'dscan_scp.txt')
  $lines = Get-Content -LiteralPath $local -Encoding UTF8
}

$all = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match 'd=\s*([\d\.]+)\s+xy=\(\s*(-?[\d\.]+),\s*(-?[\d\.]+)\)\s+n=(\d+)\s+z=\[(-?[\d\.]+) \.\. (-?[\d\.]+)\]') {
    $hd = [double]$Matches[1]; $hx = [double]$Matches[2]; $hy = [double]$Matches[3]; $hn = [int]$Matches[4]; $hz = [double]$Matches[5]
    $addr = ''
    if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match 'feet:\s*0x([0-9a-fA-F]+)') { $addr = '0x' + $Matches[1] }
    $all += [pscustomobject]@{ d=$hd; x=$hx; y=$hy; n=$hn; z=$hz; addr=$addr }
  }
}

# 邻域密度: 半径 30 单位内其它点个数
function Neighbor-Count($self, $pool) {
  $c = 0
  foreach ($p in $pool) {
    if ($p -eq $self) { continue }
    $dx = $p.x - $self.x; $dy = $p.y - $self.y
    if (([math]::Sqrt($dx * $dx + $dy * $dy)) -le 30) { $c++ }
  }
  return $c
}

$cand = @()
foreach ($p in $all) {
  if ($p.n -gt 3) { continue }
  if ($p.addr -eq '') { continue }
  $rel = $p.z - $FeetZ
  if ($rel -lt 95 -or $rel -gt 140) { continue }
  if ([math]::Abs($rel - 86.0) -lt 1.2) { continue }
  if ((Neighbor-Count $p $all) -ge 5) { continue }
  $cand += [pscustomobject]@{ d=$p.d; x=$p.x; y=$p.y; n=$p.n; z=$p.z; rel=[math]::Round($rel,1); addr=$p.addr }
}

$cand = $cand | Sort-Object d

"扫描组数=$($all.Count)  候选靶子=$($cand.Count)   自己脚底Z=$FeetZ"
""
"  距离(m)   坐标                    Z       相对高    份数   地址"
foreach ($c in $cand) {
  "  {0,7:N2}   ({1,9:N2},{2,9:N2})   {3,7:N2}  {4,6:N1}   {5,-4}  {6}" -f ($c.d / 100.0), $c.x, $c.y, $c.z, $c.rel, $c.n, $c.addr
}

if ($Save -ne '') {
  $cand | Export-Csv -LiteralPath $Save -NoTypeInformation -Encoding UTF8
  ""
  "已存档 $($cand.Count) 条 -> $Save  (打倒靶子后跑 -Diff $Save)"
}
