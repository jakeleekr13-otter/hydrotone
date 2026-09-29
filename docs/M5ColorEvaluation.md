# m5 구현 및 정적 이미지 평가 — 2026-09-29

추가로 요청한 Sea-thru 8쌍과 AquaColorFix 5쌍은
[추가 참조 이미지 확인](AdditionalReferenceReview.md)에 별도로 기록했다.

목표는 `DeveloperMedia/market/raw/m5.png`를 `ref/m5.png`의 자연스러운 모습에 가깝게
보정하면서 하단 colour panel의 색 구분도 복원하는 것이다.

**판정: 구현 후보와 평가는 완료했지만, 목표 이미지 재현 및 모든 품질 기준 통과는 미달이다.**
전체·패널·모래의 색차는 개선됐다. 일부 밝은 패치와 산호의 색감은 추가 개선이 필요하다.
시뮬레이터는 사용하지 않았다. 변경은 작업 트리에 있으며 배포하지 않았다.

## 구현

- 밝은 파란 물 장면에 충분한 중립 표면이 있을 때, 측정한 linear sRGB 채널 차이를
  유지하는 `referenceGains`/`referenceStrength`를 추가했다. 녹색 값을 빨강에 더하는
  기존 경로가 서로 다른 패치를 비슷한 회색·베이지로 만드는 문제를 줄인다.
- reference의 기하평균으로 노출을 정하고 기존 피사체 가중치로 혼합한다. 어두운 픽셀,
  밝은 중립 표면, 포화에 가까운 녹색 채널에는 적용을 줄인다. 신뢰할 reference가 없으면
  기존 경로를 사용한다. m5 이름·좌표·목표색은 보정 코드에서 사용하지 않는다.
- 새 보정 기여분에만 채널 증폭 전 노이즈 억제를 적용하고, RGB black offset의 잘림을
  완만하게 처리한다. 일반적인 전처리 denoiser와 영상 temporal denoiser는 구현하지 않았다.
- Metal/CPU 연산과 영상 장면 간 보정값 보간을 함께 수정했다.
- 원본 해상도 PNG, 패널 18개 내부 영역, 물·산호·모래 영역, 확대 비교 이미지와
  JSON 측정값을 생성하는 재실행 가능한 평가 도구를 추가했다.

알고리즘 설명은 [ColorAlgorithm.md](ColorAlgorithm.md#bright-scene-reference-adaptation-29-sep-2026),
실행 방법은 [평가 도구 README](../scripts/color-eval/README.md#m5-panel-evaluation-native-macos)에 있다.

## 평가 조건

- 기준 코드: `eb0b7a4`의 Processing 소스 스냅샷. 후보: 이번 작업 트리.
- Natural 기본값, intensity 0.8, 동일한 macOS Core Image/Core ML 실행 환경.
- m5: 1600×1066 sRGB PNG. 전체 및 영역별 CIE76 평균 색차, 작을수록 목표에 가깝다.
- 패널 점수는 18개 패치 점수의 동일 가중 평균이다. 기울어진 패널 내부만 샘플링하며
  테두리와 모래에 가려진 하단은 제외했다. `m5_regions.png`로 위치를 확인했다.
- 목표 패널은 인증된 표준 색상표가 아니다. 목표의 회색 계열에도 청록색이 남아 있다.
  목표와의 유사도와 무채색 정확도를 같은 지표로 취급하지 않는다.
- 일반 회귀 세트는 기존 도구의 640px, AquaColorFix는 960px 설정을 유지했다.
  해상도별 결과를 서로 직접 비교하지 않는다.

## m5 결과

| 영역 / 경로 | 변경 전 | 변경 후 |
|---|---:|---:|
| 전체, photo `combined` | 19.71 | 17.25 |
| 패널 18개 평균, photo | 26.89 | 20.68 |
| 모래, photo | 26.38 | 15.29 |
| 산호, photo | 16.02 | 16.20 |
| 물, photo | 16.42 | 16.43 |
| 전체, fallback `current` | 25.43 | 22.92 |
| 패널, fallback | 25.86 | 21.60 |
| 전체, 일정 깊이 `uniform` | 21.17 | 17.66 |
| 패널, 일정 깊이 | 25.78 | 19.16 |

Photo 전체 색차는 약 12.5%, 패널은 23.1%, 모래는 42.0% 감소했다.
보라색 패치 r2c1은 69.47→40.54, 파란색 r2c2는 32.76→9.76으로 개선됐다.
사진과 패널 확대 이미지를 직접 확인했다. 원본 대비 색 분리가 좋아졌지만,
목표에 비해 산호는 여전히 차갑고 물의 색·밝기도 차이가 남는다.

평균값에 가려서는 안 되는 결과:

- Photo의 밝은 노란색 r2c5는 14.00→17.14, 가장 밝은 r3c6은 8.32→9.55로 악화됐다.
  r3c5는 6.60→6.34로 유지·개선됐다. 행/열 번호는 위에서 아래, 왼쪽에서 오른쪽이다.
- Photo 모래의 고주파 색 잔차는 0.421→0.402, 물은 0.446→0.446이다.
  이것은 평탄한 영역의 노이즈 대용 지표이며 센서 노이즈 추정값이 아니다.
- 질감이 있는 산호의 같은 지표는 1.962→2.090이다. 색 복원과 실제 질감도 포함하므로
  이를 노이즈만 증가한 것으로 단정하지 않는다.
- 산호의 검은 픽셀 비율은 photo 23.11%→22.41%로 감소했지만,
  `uniform`에서는 26.98%→27.49%로 증가했다.
- `uniform` 모래의 색 잔차는 0.517→0.548이다. 영상 경로 품질 개선이 완료됐다고
  판단할 수 없다. `uniform`은 정지 이미지 대용 검사이며 실제 영상 검증이 아니다.

## 회귀 및 빌드

| 검사 | 변경 전 | 변경 후 / 결과 |
|---|---:|---:|
| UIEB dev 40장, photo 평균 색차 | 19.0184 | 18.9469 |
| UIEB dev 40장, uniform | 18.6710 | 18.5903 |
| UIEB holdout 40장, photo | 20.4373 | 20.3411 |
| UIEB holdout 40장, uniform | 20.4364 | 20.3539 |
| AquaColorFix gate, photo | 12.31 | 12.27 |
| AquaColorFix gate, uniform | 12.85 | 12.82 |
| 중립색 램프 max Lab chroma | 0.01 | 0.01 |
| macOS native 검증 | — | 72개 통과 |
| iOS generic device Debug 빌드, 서명 비활성 | — | 성공 |

Native 검증은 Metal/CPU 일치, 색공간 왕복, reference 증거, Original 유지,
어두운/중립 장면 보호, 유색 채널 구분, 포화 보호, 어두운 채널 보존을 검사한다.
빌드는 실제 앱과 영상 보간 코드를 포함한다. iOS XCTest/UI 테스트나 기기 실행을
통과했다고 주장하지 않는다.

Market 6장, 실제 촬영 15장, UIEB dev/holdout과 challenging 8장도 렌더링했다.
Dev/holdout의 물 indigo/violet 분류 개수는 증가하지 않았다. 기존 녹색 물 처리 문제는
이번 수정으로 해결되지 않았다. Holdout 결과는 최종 후보 고정 후 비교했으며 튜닝에
사용하지 않았다.

개별 이미지 회귀도 있다. Dev의 `114_img_.png`는 photo 색차 +2.12,
uniform +2.17이며, holdout의 `144_img_.png`는 uniform +1.53이다.
평균이 개선됐다는 이유로 이 회귀를 통과로 처리하지 않았다.

기존의 엄격한 “모든 중립 표면 chroma가 증가하지 않아야 한다” 기준은 전부 충족하지
못했다. 640px 보고서의 m5 모래는 0.018→0.019, m6 배는 0.028→0.029였다.
따라서 평균 색차 개선과 빌드 성공을 전체 품질 승인으로 해석하지 않는다.

## 재실행과 산출물

```sh
scripts/color-eval/native_checks.sh
scripts/color-eval/m5_eval.sh m5-final-20260929 /path/to/baseline/render
scripts/color-eval/tune_eval.sh m5-final2-dev-20260929
scripts/color-eval/aquacolorfix_eval.sh m5-final2-aqua-20260929
scripts/color-eval/run_eval.sh m5-final2-holdout-20260929 holdout:40
```

결과 루트는 `${TMPDIR}/underblue-color-eval`이다. 개발 이미지와 생성 결과는 앱/테스트
번들에 추가하지 않았다. 최종 m5 폴더의 `render/m5_comparison.png`, `m5__combined.png`,
`m5_regions.png`, `m5_metrics.json` 및 상위 `report.txt`, `m5.log`에 근거를 남겼다.
빌드 로그는 로컬 `/tmp` 임시 파일에 남겼다.

후속 작업은 산호의 남은 청록색과 포화된 밝은 패치, 일정 깊이 경로의 모래/암부를
해결하는 것이다. 전체 휘도 계수 교체, 물 hue 정책 변경, plan confidence 재설계,
일반 입자 제거·deblur·실제 영상 속도 측정은 이번 구현에 포함하지 않았다.
