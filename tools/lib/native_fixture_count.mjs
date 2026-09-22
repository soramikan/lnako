// tests/oracle/native-cases.json のfixture基数を一元管理する。
// check_native_aot_artifacts.mjs と verify_native_aot_attestation.mjs が
// 同じfixture集合を検証するため、期待件数をここへ集約して片方だけの
// 更新漏れによる不一致を防ぐ。fixtureを追加・削除したらこの定数を更新する。
export const expectedNativeFixtureCount = 387;
