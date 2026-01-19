# CRaC CI - Central CI Repository

통합 CI 저장소입니다. 여러 저장소에서 재사용 가능한 GitHub Actions workflows와 composite actions를 제공합니다.

## 구조

```
crac-ci/
├── .github/
│   └── workflows/
│       ├── crac-check.yaml      # CRaC 호환성 검증 Reusable Workflow
│       ├── helm-validate.yaml   # Helm 차트 검증 Reusable Workflow
│       └── kind-validate.yaml   # Kind 클러스터 설정 검증 Reusable Workflow
├── actions/
│   ├── crac-analysis/           # CRaC 분석 Composite Action
│   ├── helm-lint/               # Helm lint Composite Action
│   └── kind-check/              # Kind 검증 Composite Action
├── scripts/
│   ├── check-crac-compatibility.sh  # CRaC 호환성 분석 스크립트
│   └── validate-helm.sh             # Helm 검증 스크립트
└── README.md
```

---

## Reusable Workflows 사용법

### 1. CRaC 호환성 검증 (crac-check.yaml)

Java 소스 코드에서 CRaC 비호환 패턴을 정적 분석합니다.

```yaml
# .github/workflows/ci.yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  crac-check:
    uses: YOUR_ORG/crac-ci/.github/workflows/crac-check.yaml@main
    with:
      source-path: './src/main/java'
      output-format: 'markdown'
      fail-on-error: true
      fail-on-warning: false
      min-java-version: '17'
      java-version: '21'
```

#### 입력 파라미터

| 파라미터 | 필수 | 기본값 | 설명 |
|---------|------|--------|------|
| `source-path` | No | `./src/main/java` | Java 소스 디렉토리 경로 |
| `output-format` | No | `text` | 출력 형식: text, json, markdown |
| `fail-on-error` | No | `true` | ERROR 발견 시 실패 처리 |
| `fail-on-warning` | No | `false` | WARNING 발견 시 실패 처리 |
| `min-java-version` | No | `17` | 최소 Java 버전 |
| `upload-report` | No | `true` | 분석 리포트 아티팩트 업로드 |
| `java-version` | No | `21` | 설정할 Java 버전 |

#### 출력

| 출력 | 설명 |
|-----|------|
| `error-count` | ERROR 레벨 이슈 수 |
| `warning-count` | WARNING 레벨 이슈 수 |
| `has-errors` | ERROR 이슈 존재 여부 |

---

### 2. Helm 차트 검증 (helm-validate.yaml)

Helm 차트의 lint와 template 렌더링을 검증합니다.

```yaml
# .github/workflows/ci.yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    paths:
      - 'helm/**'

jobs:
  helm-validate:
    uses: YOUR_ORG/crac-ci/.github/workflows/helm-validate.yaml@main
    with:
      chart-path: './helm/my-app'
      kube-version: '1.29.0'
      strict: false
      helm-version: '3.14.0'
```

#### 입력 파라미터

| 파라미터 | 필수 | 기본값 | 설명 |
|---------|------|--------|------|
| `chart-path` | **Yes** | - | Helm 차트 디렉토리 경로 |
| `values-file` | No | `''` | 추가 values 파일 |
| `kube-version` | No | `1.29.0` | 검증할 Kubernetes 버전 |
| `strict` | No | `false` | strict 모드 (warning도 실패 처리) |
| `helm-version` | No | `3.14.0` | 사용할 Helm 버전 |
| `upload-manifests` | No | `true` | 렌더링된 매니페스트 아티팩트 업로드 |

#### 출력

| 출력 | 설명 |
|-----|------|
| `lint-passed` | helm lint 통과 여부 |
| `template-passed` | helm template 통과 여부 |

---

### 3. Kind 클러스터 설정 검증 (kind-validate.yaml)

Kind 클러스터 설정 파일을 검증합니다.

```yaml
# .github/workflows/ci.yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    paths:
      - 'kind/**'

jobs:
  kind-validate:
    uses: YOUR_ORG/crac-ci/.github/workflows/kind-validate.yaml@main
    with:
      config-path: './kind/cluster-config.yaml'
      kind-version: '0.22.0'
      validate-schema: true
```

#### 입력 파라미터

| 파라미터 | 필수 | 기본값 | 설명 |
|---------|------|--------|------|
| `config-path` | **Yes** | - | Kind 클러스터 설정 파일 경로 |
| `kind-version` | No | `0.22.0` | 사용할 Kind 버전 |
| `kubernetes-version` | No | `''` | 예상 Kubernetes 버전 |
| `validate-schema` | No | `true` | Kind 스키마 검증 (dry-run) |
| `check-node-config` | No | `true` | 노드 설정 검증 |

#### 출력

| 출력 | 설명 |
|-----|------|
| `valid` | 설정 유효성 |
| `node-count` | 설정된 노드 수 |

---

## Composite Actions 사용법

개별 workflow step으로 사용할 때는 composite action을 직접 참조합니다.

### 1. CRaC Analysis Action

```yaml
steps:
  - uses: actions/checkout@v4

  - name: CRaC Analysis
    uses: YOUR_ORG/crac-ci/actions/crac-analysis@main
    with:
      source-path: './src/main/java'
      output-format: 'json'
      output-file: 'crac-report.json'
      fail-on-error: 'true'
```

### 2. Helm Lint Action

```yaml
steps:
  - uses: actions/checkout@v4

  - name: Helm Lint
    uses: YOUR_ORG/crac-ci/actions/helm-lint@main
    with:
      chart-path: './helm/my-app'
      values-file: './helm/my-app/values-prod.yaml'
      kube-version: '1.29.0'
      strict: 'false'
```

### 3. Kind Check Action

```yaml
steps:
  - uses: actions/checkout@v4

  - name: Kind Validation
    uses: YOUR_ORG/crac-ci/actions/kind-check@main
    with:
      config-path: './kind/cluster-config.yaml'
      kind-version: '0.22.0'
      validate-schema: 'true'
```

---

## 전체 예시: Java 앱 CI 파이프라인

```yaml
# .github/workflows/ci.yaml
name: Java App CI

on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  # CRaC 호환성 검증
  crac-analysis:
    uses: YOUR_ORG/crac-ci/.github/workflows/crac-check.yaml@main
    with:
      source-path: './src/main/java'
      fail-on-error: true
      output-format: 'markdown'

  # Helm 차트 검증
  helm-validate:
    uses: YOUR_ORG/crac-ci/.github/workflows/helm-validate.yaml@main
    with:
      chart-path: './helm/my-app'
      kube-version: '1.29.0'

  # 빌드 및 테스트 (CRaC 분석 통과 후)
  build:
    needs: crac-analysis
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '21'

      - name: Build
        run: ./mvnw clean package -DskipTests

      - name: Test
        run: ./mvnw test
```

---

## 전체 예시: 인프라 저장소 CI 파이프라인

```yaml
# .github/workflows/infra-ci.yaml
name: Infrastructure CI

on:
  push:
    branches: [main]
  pull_request:
    paths:
      - 'helm/**'
      - 'kind/**'

jobs:
  helm-validate:
    uses: YOUR_ORG/crac-ci/.github/workflows/helm-validate.yaml@main
    with:
      chart-path: './helm/app-chart'

  kind-validate:
    uses: YOUR_ORG/crac-ci/.github/workflows/kind-validate.yaml@main
    with:
      config-path: './kind/cluster.yaml'

  deploy-check:
    needs: [helm-validate, kind-validate]
    runs-on: ubuntu-latest
    steps:
      - name: All validations passed
        run: echo "Infrastructure validation complete!"
```

---

## 로컬 스크립트 사용

스크립트를 로컬에서 직접 실행할 수도 있습니다.

### CRaC 호환성 분석

```bash
# 기본 사용
./scripts/check-crac-compatibility.sh ./src/main/java

# JSON 형식으로 출력
./scripts/check-crac-compatibility.sh -f json -o report.json ./src/main/java

# Markdown 리포트 생성
./scripts/check-crac-compatibility.sh -f markdown -o report.md ./src/main/java

# Warning도 실패 처리
./scripts/check-crac-compatibility.sh --fail-on-warning ./src/main/java
```

### Helm 검증

```bash
# 기본 사용
./scripts/validate-helm.sh ./helm/my-app

# values 파일 지정
./scripts/validate-helm.sh -f values-prod.yaml ./helm/my-app

# strict 모드
./scripts/validate-helm.sh --strict ./helm/my-app

# 렌더링된 매니페스트 저장
./scripts/validate-helm.sh -o ./rendered ./helm/my-app
```

---

## 버전 관리

안정적인 CI를 위해 특정 버전 또는 커밋을 참조하는 것을 권장합니다:

```yaml
# 태그 사용 (권장)
uses: YOUR_ORG/crac-ci/.github/workflows/crac-check.yaml@v1.0.0

# 브랜치 사용
uses: YOUR_ORG/crac-ci/.github/workflows/crac-check.yaml@main

# 특정 커밋 사용
uses: YOUR_ORG/crac-ci/.github/workflows/crac-check.yaml@abc1234
```

---

## 요구사항

- GitHub Actions
- Helm 3.x (helm-validate용)
- Kind 0.20+ (kind-validate용)
- Bash 4.0+
