# 追加性能改善レビュー（2026-09-07）

ユーザー提供レビューの全文を以下に保存する。数値・現状評価は提供時点の記述であり、実装後の測定結果ではない。実装・検証の進捗は [実施計画](PERFORMANCE_PLAN_M8_M15.md) で管理する。

---

最新版を確認しました。現行`main`は **`3c417fab192bbb8648a33525d02fbf9944ae8380`**、最新CIベンチマークの実測対象は **`c720465342c10235877a97ee953d148e5d9469a4`**、ローカル測定は`aa356cf...`です。`main`との差は主に証拠・結果文書側なので、性能判断は9月7日のCI値を基準にし、実装構造は現行`main`を参照するのが妥当です。

前回の重点項目はかなり効いています。特に**AOTの辞書検索問題は解消済み**で、`hash-lookup`はLinux 49.67 ms、macOS 50.96 ms、Windows 81.59 msとなり、すべてgonakoを上回っています。現行AOTには辞書索引と文字列キーの無変換検索が入り、文字列連結にもborrowed operand方式が導入されています。またInterpreterにもValue buffer再利用や8引数までのstack argumentが入っています。

## 現時点での結論

次のフェーズでは、**AOTの個別ボトルネック修正から、Interpreterの構造的高速化とAOTの値表現・GC root・関数ABI最適化へ重点を移すべきです。**

AOTは現在、Linuxでは19実行ケースすべてInterpreterより高速で、gonakoに負けるのは`string-concat`だけです。macOSでもgonakoに負けるのは`string-concat`だけ、Windowsでは`string-concat`と`nbody`だけです。一方、Interpreterは19ケース中Linux/Windowsで16ケース、macOSで15ケースがgonakoより遅い状態です。

したがって次の優先順位を推奨します。

| 優先度    | 対象                                            | 目的                                 |
| ------ | --------------------------------------------- | ---------------------------------- |
| **P0** | Interpreterのprepared execution / local slot化  | 全般的な5〜10倍差を縮める                     |
| **P0** | AOTの非capture binding cell除去                   | 関数・再帰・数値処理の固定費削減                   |
| **P0** | AOT GC rootのliveness化                         | 全AOTコードのstack/root traffic削減       |
| **P1** | `string-concat`                               | 唯一の3 OS共通gonako敗北ケースを解消            |
| **P1** | typed AOT internal ABI                        | Number主体処理を`Value` boxingから解放      |
| **P1** | Windows `nbody`                               | OS固有のAOT差を特定・解消                    |
| **P2** | Interpreter builtin dispatch / indexed access | 配列・数値・文字列ループを改善                    |
| **P2** | GC allocator / small object                   | binary-trees等のallocation workloads |
| **P2** | compile pipeline                              | 0.8〜1秒級のcompile-stressを削減          |
| **P3** | AOT runtime dead-strip / executable size      | 7〜9 MB級バイナリを縮小                     |

---

# 1. 最優先：Interpreterを「IRを直接読む実装」から実行用IRへ変える

ここが今後最大の改善余地です。

現在も`executeFunction()`は呼び出し時に`maxValueId()`を計算しています。またframeはValue bufferを再利用するよう改善されていますが、local変数は依然として名前をキーとした`frame.locals`から取得しています。`localValue()`も`frame.locals.get(name)`です。

演算子については以前の多数の`std.mem.eql()`から`StaticStringMap`へ改善されていますが、それでも各命令実行時に文字列からenumを検索しています。

ここをさらに一段進めます。

## `PreparedProgram` / `PreparedFunction`を導入する

構文解析→SSA検証→最適化までは現行IRを保持し、その後Interpreter専用の実行表現を一度作ります。

概念的には、

```text
IR
 ↓
verify / optimize
 ↓
PreparedFunction
  - value_count
  - local slot mapping
  - resolved operators
  - resolved direct callee
  - resolved builtin opcode
  - block pointers/index
  - capture mapping
  - source/debug metadata
 ↓
Interpreter
```

とします。

### ローカル変数を名前ではなくslotにする

例えば、

```text
A → local[0]
I → local[1]
S → local[2]
```

のようにコンパイル時またはprepare時に決めます。

現在の、

```zig
frame.locals.get(instruction.name)
```

をhot pathから除き、

```zig
frame.local_cells[instruction.local_slot]
```

のようにします。

ただしcaptureされた変数は依然としてcellを共有する必要があります。

したがって内部表現を、

```text
LocalStorage =
    direct Value
    BindingCell*
```

のように分けるのがよいです。

非capture変数なら`Value`を直接frameに置き、captureされた変数だけBindingCellを使います。

これはInterpreterでもAOTでも共通の解析として使えます。

### 演算子をprepare時にenum化

現在は改善済みとはいえ、

```zig
binary_operators.get(instruction.operator)
```

が実行時に残っています。

これを、

```text
binary "+"
   ↓ prepare
BinaryOp.add
```

として、実行ループでは単純なenum switchにします。

同様に、

```text
builtin名
関数名
global名
local名
```

も解決可能なものは整数ID化します。

### `maxValueId()`もprepare時に一度だけ

現在のValue buffer pool自体は良い改善なので残し、

```text
prepared.value_count
```

を使って取得します。

さらにValue bufferをsize class化します。

例えば、

```text
16
32
64
128
256
...
```

単位でfree-listを持つと、異なる関数サイズ間でも再利用しやすくなります。

## 期待される対象

特にInterpreterでgonakoとの差が大きい、

```text
integer-arithmetic
branch-mix
nbody
array-scan
sieve
word-count
```

へ横断的に効きます。

Linuxでは例えばInterpreterが、

`branch-mix` 1080.42 ms 対 gonako 166.18 ms、`array-scan` 755.36 ms 対110.37 ms、`sieve` 463.88 ms 対40.31 msです。

個別builtinを数%改善するより、まずこの実行器固定費を落とすべきです。

---

# 2. AOT：非capture localのBindingCellをなくす

前回提案した中で、これはまだ主要部分が残っています。

現行`writeFunction()`を見ると、非capture localにも依然として、

```llvm
call @lnako_aot_binding_cell_new
call @lnako_aot_binding_cell_value
```

を生成しています。

これは現在のAOTで最も明確な次の改善候補です。

## escape/capture解析を共通passとして追加

各localについて、

```text
captured?
address/identityが外へ逃げる?
dynamic executionから参照される?
callbackから変更され得る?
```

を判定します。

そして、

| 種別               | 実装               |
| ---------------- | ---------------- |
| 非capture、非escape | stack/SSA上のValue |
| 型既知＋非capture     | primitive SSA    |
| captureされる       | BindingCell      |
| 不明               | BindingCell      |

とします。

例えば単純な再帰、

```text
●F(N)
...
```

の`N`や内部一時変数がclosureから観測されないなら、heap cellを作る理由はありません。

## 最初は「Value stack slot化」だけでよい

いきなりprimitive SSAまでやる必要はありません。

第一段階は、

```text
BindingCell allocation
↓
alloca %lnako.Value
```

へするだけでもよいです。

この変更なら意味論リスクが比較的小さく、heap allocationとGC対象を減らせます。

### 受け入れ条件

例えば`function-call`や`recursion`について、

```text
binding_cells_created_per_call = 0
```

となる関数を明示的にテストします。

capture benchmarkでは必要なcell数が変わらないことも確認します。

---

# 3. AOT rootを「全SSA値」から「GC時に生存する参照」にする

現在のAOTは関数ごとに、

```zig
value_root_count = functionValueCount(function)
root_count = value_root_count + locals.len
```

として、ほぼ全Value ID分のroot slotを確保・初期化しています。

これは正しさ優先としては安全ですが、性能面ではかなり保守的です。

## GC safepoint解析を導入する

GCが走り得る命令を、

```text
allocation
builtin call
user callback
dynamic execution
string creation
array/dictionary creation
```

などに分類します。

その地点ごとに、

```text
その先でも使用される
かつ
GC-managed objectを保持し得る
```

Valueだけをrootにします。

Number、Boolean、Null、Undefinedはroot不要です。

### root slot coloring

生存区間が重ならない値は同じroot slotを共有します。

例えば、

```text
v1 lifetime ─────
                  v4 lifetime ───
```

なら同じslotを使えます。

結果として、

```text
100 SSA values
→ 実際の同時live GC referencesは8
```

ならroot arrayを100→8にできます。

### ここはAOT全体に効く

`integer-arithmetic`のようなほぼprimitiveの処理では、理想的にはroot操作自体をほぼ消せます。

現時点でもAOTはかなり高速化しましたが、C/Rustとの差は大きいです。Linuxの`integer-arithmetic`はAOT 58.01 msに対しC 2.08 ms、Rust 2.28 msです。

この差を詰めるには、runtime関数の微調整ではなく生成コードをprimitive compilerに近づける必要があります。

---

# 4. Typed SSA / typed internal ABIを本格化する

AOTの次の大きな段階です。

現在の関数ABIは依然として、

```llvm
%lnako.Value
```

中心です。

例えばNumberだけ扱う内部関数なら、

```llvm
define double @fn(double)
```

という形の方が圧倒的に最適化しやすくなります。

## generic ABIとspecialized ABIを両立する

例えば、

```text
fn_generic(Value) -> Value
fn_number(double) -> double
```

を用意します。

静的に型が分かるcall siteでは`fn_number`へ直接call。

動的呼び出し・callback・pluginなどではgeneric wrapperを使います。

これなら互換性を落としません。

## 最初に特殊化すべき型

まず、

```text
Number
Boolean
```

だけで十分です。

StringやArrayの特殊化は後に回します。

### integer-arithmetic / branch-mix / nbody / sieveが主対象

特に、

```text
X = X*1664525 + ...
I=I+1
S=S+...
```

のようなループを、

```text
double
```

または意味論上安全なら整数系内部表現で保持できれば大幅に改善できます。

ただし、なでしこのNumber意味論がJavaScript系である以上、**単純にi64化してはいけません**。

基本はbinary64を保持し、

```text
NaN
±Infinity
-0
```

を維持します。

---

# 5. `string-concat`を次のAOT最優先個別ケースにする

辞書問題が解消した現在、**3 OSすべてでAOTがgonakoより遅い唯一の本格的ケースが`string-concat`です。**

現在値は、

| OS      | gonako |   AOT | AOT/gonako |
| ------- | -----: | ----: | ---------: |
| Linux   |  23.77 | 28.33 |      1.19x |
| macOS   |  31.77 | 58.82 |      1.85x |
| Windows |  49.51 | 88.55 |      1.79x |

です。WindowsではさらにInterpreter 81.22 msよりAOT 88.55 msの方が遅いです。

借用operand化はすでに実装されています。現行`concat()`はUTF-16文字列とstatic UTF-8 literalを借用し、一時コピーを避けています。

したがって次に見るべきは**出力側**です。

## 計測を追加する

`string-concat`について、

```text
concat_calls
output_utf16_bytes
object_allocations
payload_allocations
GC_cycles
GC_scan_objects
allocator_realloc/malloc count
```

を取得します。

特に、

```text
UTF-16 payload allocation
Object allocation
GC registration
```

がそれぞれ別allocationになっていないか確認します。

### String object + payloadの一体allocation

現在のオブジェクト表現次第ですが、可能なら、

```text
[StringHeader][UTF16 units...]
```

の1 allocationにまとめる余地があります。

現在、

```text
buffer allocation
+
GC Object allocation
```

が別なら、短命文字列を大量生成するケースでは影響します。

### exact-size allocation用fast path

concat結果は最終長が事前に分かっています。

従って、

```text
createStringCopy()
```

ではなく、

```text
allocStringUninitialized(length)
write units directly
```

のようにします。

現在の`ConcatOperand.write()`はこの構造と相性が良いです。

### 特殊なin-place最適化は後段

```text
S = S & "ab"
```

のような自己更新をcopy-on-write builderへ変換することも可能ですが、今回のbenchmarkはimmutable copy-on-concatを意図しているため、**まずは同じ意味論・同じコピー量のまま高速化**してください。

---

# 6. Windows `nbody`を独立したプロファイル対象にする

Windowsでは唯一もう一つ、

```text
gonako 61.39 ms
AOT    91.85 ms
```

と負けています。一方LinuxではAOT 15.57 ms対gonako 46.87 ms、macOSでは11.76 ms対40.40 msで大幅に勝っています。

これは**言語処理系全般の設計問題ではなく、Windows固有要因の可能性が高い**です。

ここは推測で変更せず、Windows上で、

```text
CPU sampling profile
generated LLVM IR
generated assembly
import table
runtime call count
array_get/set calls
sqrt calls
stack probing
```

を比較してください。

特に確認すべきなのは、

```text
__chkstk
Win64 ABIによるaggregate Value受け渡し
外部runtime callのinline不能
array access helper call
```

です。

もし`%lnako.Value`の16-byte前後のaggregate受け渡しがWin64 ABIで高価なら、typed internal ABIの導入がこの問題も同時に解消します。

したがって、**Windows専用hackを先に入れるより、typed ABIの実装と並行して測る**方がよいです。

---

# 7. Interpreterの関数呼び出しはもう一段改善できる

stack argument化は既に実装されています。8引数以下ならheap allocationを避けています。

次は、

```text
findFunction()
localValue(name)
globals.get(name)
callBuiltin(name)
```

という名前ベースの分岐をprepare時に解決します。

例えばcall instructionに、

```text
CallTarget =
  direct_ir(FunctionId)
  local_slot(slot)
  global_slot(slot)
  builtin(BuiltinOpcode)
  dynamic
```

を持たせます。

すると普通の静的関数呼び出しなら、

```text
switch(target)
  .direct_ir => executeFunction(...)
```

だけになります。

### `それ`へのstoreも解析する

現在は関数呼び出し後に`それ`更新の判断があります。

`それ`が以降一度も読まれない場合にstoreを省略できるか検討します。

ただしglobal traceや動的実行から観測可能なら省略してはいけません。

したがって、

```text
may_observe_global("それ")
```

をeffect解析の一部にします。

---

# 8. Interpreterのinterrupt checkをblock単位へ減らせるか検討する

現在`executeFunction()`では各instructionごとに、

```zig
try self.handleNodeInterrupt();
```

を実行しています。

これはループ主体benchmarkではかなりの頻度になります。

互換性が許せば、

```text
block entry
backedge
call
allocation
long-running builtin
```

などのsafepointに限定できます。

例えば、

```text
各命令 100M回
↓
loop backedge 10M回
```

へ減らせます。

ただし割り込み応答性に影響するので、

```text
最大命令数Nごと
```

のbudget counterと組み合わせるのもよいです。

これはPrepared Interpreterと非常に相性が良い改善です。

---

# 9. Interpreter localについてBindingCellそのものも減らす

Interpreter側も`bindLocal()`でBindingCellを作る構造が残っているなら、AOTと同じescape解析結果を共有します。

理想形は、

```text
普通のlocal → frame.values/local_values
captured local → BindingCell
```

です。

この変更により、

```text
function-call
recursion
branch-mix
numeric loops
```

のGC allocationが減ります。

特にInterpreterの`recursion`は、

Linux 987.77 ms対gonako 810.45 ms、macOS 692.66 ms対496.27 ms、Windows 994.34 ms対808.17 msで、他のケースほど差が大きくありません。

つまりこのケースは、frame/cell/call固定費を落とせば**比較的早くgonako超えを狙えるケース**です。

---

# 10. 小配列・数値配列の特殊化は、その後

現在のAOT配列性能はかなり改善しています。

例えばLinuxで、

```text
array-build  AOT 5.74 ms / gonako 56.12 ms
array-scan   AOT 26.43 ms / gonako 110.37 ms
sieve        AOT 14.30 ms / gonako 40.31 ms
```

です。

したがって、以前の「配列fast path」は最優先ではなくなりました。

次に行うなら、

```text
Array<Value>
↓
packed NumberArray
```

のような内部specializationですが、これはかなり大規模な変更です。

typed SSA・typed ABIを先に完成させ、**array element typeのフィードバックとして使える状態になってから**進める方がよいです。

---

# 11. GCは「方式変更」より前にallocation sourceを減らす

`binary-trees`はすでにAOTがgonakoより速いです。

Linux 21.75 vs 51.40、macOS 26.76 vs69.99、Windows44.92 vs77.79です。

従って、この段階で世代別GCへ全面移行する優先度は低いです。

まず、

```text
BindingCell削減
root削減
string object allocation削減
frame allocation削減
```

を行います。

その後、GC統計を追加し、

```text
allocated bytes
objects created
collections
mark time
sweep time
peak live bytes
```

を測って初めて、

```text
nursery
arena/slab
generational GC
```

を評価します。

---

# 12. コンパイル性能はruntimeと独立して改善する

`compile-stress-medium`はLinuxで811.95 msです。macOS・Windowsも数百ms〜1秒近辺です。

以前のSSA verifier改善後なので、次は各段階を分けてください。

```text
parse
AST lowering
SSA construction
verification
optimization
LLVM IR emission
LLVM parse
LLVM optimization
object generation
link
```

を個別計測します。

特に現行optimizerの、

```text
inferTypes
inferReturnTypes
inferParameterTypes
```

の固定点計算は、プログラム全体の繰り返し走査になりやすいので、

```text
def-use worklist
call graph SCC
```

ベースに移行する余地があります。

また、

```text
ValueId → definition
Function name → FunctionId
local name → slot
```

のindexをcompiler全体で共有すると、runtime側のPrepared IR構築にも利用できます。

---

# 13. 実行ファイルサイズは明確に改善余地がある

興味深いのはmacOSで、一部の生成物だけ約300〜400 KiBまで小さくなっている一方、多くのケースは約7.5 MiBです。

例えば、

```text
startup-empty    321,040 bytes
closure-call     405,184 bytes
integer-arithmetic 7,510,144 bytes
```

です。

これは**必要runtime機能のdead stripが部分的には機能している**証拠でもあります。

どのsymbol referenceがfull runtimeを引き込むかmap fileで分析するとよいです。

特に巨大な、

```text
lnako_aot_builtin_call_site
```

dispatcherへの1参照が大量のbuiltin実装を引き込んでいる可能性があります。

すでに`array_push`や`element_count`の専用ABIが追加されています。現行`state.zig`からも専用exportが確認できます。

この方式を、

```text
数学
基本配列
文字列
JSON
I/O
```

のhot builtinへ適切に拡張すると、

**性能とdead-stripの両方**に効く可能性があります。

ただしすべてを個別ABIにするのではなく、

```text
hot + pure + signature fixed
```

なbuiltinだけに限定します。

---

# 新しい実装ロードマップ

次はこの順序がよいです。

1. **M8: Interpreter Prepared IR**
   local/global/function/builtin/operatorを事前解決し、`value_count`も保存。既存IRは検証・診断用に残す。

2. **M9: Shared local escape/capture analysis**
   Interpreter/AOT双方で非capture localをBindingCellから外す。まず`Value` stack slot、後でprimitive SSAへ昇格。

3. **M10: AOT root liveness / safepoint analysis**
   primitive root除去、dead root除去、slot coloringを実装する。

4. **M11: Typed AOT ABI Phase 1**
   Number/Booleanだけ特殊化。generic wrapperは残す。`integer-arithmetic`、`branch-mix`、`function-call`、`recursion`で検証。

5. **M12: String allocation fast path**
   concat用uninitialized String allocation、Object+payload一体化の可否、GC registrationコスト削減。3 OSでgonako超えを目標にする。

6. **M13: Windows numeric profile**
   `nbody`のWin64生成コードをsampling＋assemblyで分析。typed ABIとの相互作用を確認してからWindows専用対応を判断。

7. **M14: Interpreter safepoint / dispatch reduction**
   per-instruction interrupt checkをbackedge/call/budget方式へ。direct call、builtin opcode、global/local slotをhot path化。

8. **M15: Compiler worklist + runtime dead strip**
   compiler pipelineの索引化・worklist化と、AOT runtime feature slicingを実施。

---

## 次回ベンチマークで追加したいケース

現在の20ケースはかなり良くなっていますが、次の最適化フェーズでは少しだけ追加すると診断力が大きく上がります。

| 新規ケース                   | 意図                          |
| ----------------------- | --------------------------- |
| `local-load-store`      | local slot化だけを測る            |
| `global-load-store`     | global lookup/storeを分離      |
| `direct-call-empty`     | 関数frame/cell/ABIだけを測る       |
| `captured-call-empty`   | BindingCell必要経路を比較          |
| `array-read-only`       | buildを除いた純粋なindex scan      |
| `array-write-only`      | build済み配列へのsetのみ            |
| `dict-small`            | 4〜8 keyの小辞書性能               |
| `dict-large-read`       | 構築済み大辞書のlookupのみ            |
| `string-copy-fixed`     | concat allocation/copyだけを測る |
| `gc-short-lived`        | 大量の短命object                 |
| `gc-long-lived`         | root scanの影響                |
| `numeric-function-call` | typed ABIの効果                |

特に`array-scan`は現在「構築＋走査」、`hash-lookup`も「構築＋検索」なので、次の最適化ではread/write/buildを分離したmicrobenchmarkが必要になります。

## 性能目標

次フェーズでは単純に「全部C並み」を目標にするより、段階的な基準が適切です。

| 対象                    | 次の目標                   |
| --------------------- | ---------------------- |
| AOT vs cnako          | 全steady-stateで勝つ       |
| AOT vs gonako         | 全3 OS・全steady-stateで勝つ |
| AOT vs Interpreter    | startupのノイズ以外で全ケース勝つ   |
| Interpreter vs cnako  | 過半数以上で勝つ               |
| Interpreter vs gonako | まず2倍以内、その後1倍以下を狙う      |
| AOT numeric vs C/Rust | 現状10〜30倍差 → 5倍以内       |
| `string-concat`       | gonako以下               |
| Windows `nbody`       | gonako以下               |
| compile-stress        | 現状比30%以上削減             |
| AOT size              | 小規模プログラムで1 MiB未満を標準化   |

今回の改善で、**AOTの「明らかなアルゴリズム上の欠陥」はかなり解消されました**。次は`Value`、BindingCell、GC root、文字列名lookupといった**動的言語としての汎用性のために払っている固定費を、静的に証明できる場所では払わない設計へ進む段階**です。

特に **Prepared Interpreter → shared escape analysis → AOT root liveness → typed ABI** の4段階は互いに解析情報を共有できるため、別々の場当たり的最適化ではなく、1本のcompiler/runtime最適化基盤として設計するのが最も効果的です。
