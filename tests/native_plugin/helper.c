/* `--bundle-deps` の推移的依存 fixture（Issue #56）。
 *
 * `fixture_with_dependency.c` の plugin がこの library へ依存する。
 * plugin 側から参照される単純な関数だけを公開し、plugin の payload 同梱
 * （private 共有ライブラリの複製と先読み）を検証できるようにする。 */
#include <stdint.h>

int32_t lnako_dependency_double(int32_t value) { return value * 2; }
