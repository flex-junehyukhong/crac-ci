#!/bin/bash
# =============================================================================
# Helm 차트 검증 스크립트
# =============================================================================
# Helm 차트의 문법 검사, 매니페스트 렌더링, 베스트 프랙티스 검증을 수행합니다.
#
# 사용법: ./validate-helm.sh [OPTIONS] <chart_path>
# =============================================================================

set -euo pipefail

VERSION="1.0.0"

# -----------------------------------------------------------------------------
# 설정 변수
# -----------------------------------------------------------------------------
CHART_PATH=""
VALUES_FILE=""
OUTPUT_DIR=""
STRICT_MODE="false"
KUBE_VERSION=""
VERBOSE="false"

# 결과
LINT_PASSED="false"
TEMPLATE_PASSED="false"
ERROR_COUNT=0
WARNING_COUNT=0

# =============================================================================
# 함수 정의
# =============================================================================

usage() {
    cat << EOF
Helm 차트 검증 스크립트 v${VERSION}

사용법: $0 [OPTIONS] <chart_path>

OPTIONS:
  -f, --values <file>       추가 values 파일
  -o, --output <dir>        렌더링된 매니페스트 출력 디렉토리
  --strict                  strict 모드 (warning도 실패 처리)
  --kube-version <ver>      Kubernetes 버전 지정 (예: 1.28.0)
  -v, --verbose             상세 로그
  -h, --help                도움말

예제:
  $0 ./helm-charts/my-app
  $0 -f values-prod.yaml ./helm-charts/my-app
  $0 --strict --kube-version 1.28.0 ./helm-charts/my-app

EOF
}

log() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

info() {
    echo "[INFO] $*"
}

error() {
    echo "[ERROR] $*" >&2
}

warn() {
    echo "[WARN] $*" >&2
}

# Helm 설치 확인
check_helm() {
    if ! command -v helm &> /dev/null; then
        error "Helm is not installed"
        exit 2
    fi

    local helm_version
    helm_version=$(helm version --short 2>/dev/null | head -1)
    log "Helm version: ${helm_version}"
}

# 차트 구조 검증
validate_chart_structure() {
    local chart_path="$1"

    info "Validating chart structure..."

    # 필수 파일 확인
    if [[ ! -f "${chart_path}/Chart.yaml" ]]; then
        error "Chart.yaml not found in ${chart_path}"
        ((ERROR_COUNT++))
        return 1
    fi

    if [[ ! -f "${chart_path}/values.yaml" ]]; then
        warn "values.yaml not found (optional but recommended)"
        ((WARNING_COUNT++))
    fi

    if [[ ! -d "${chart_path}/templates" ]]; then
        error "templates/ directory not found"
        ((ERROR_COUNT++))
        return 1
    fi

    # Chart.yaml 필수 필드 확인
    local chart_name chart_version
    chart_name=$(grep -oP '(?<=^name:\s).*' "${chart_path}/Chart.yaml" 2>/dev/null || echo "")
    chart_version=$(grep -oP '(?<=^version:\s).*' "${chart_path}/Chart.yaml" 2>/dev/null || echo "")

    if [[ -z "$chart_name" ]]; then
        error "Chart name not defined in Chart.yaml"
        ((ERROR_COUNT++))
    fi

    if [[ -z "$chart_version" ]]; then
        error "Chart version not defined in Chart.yaml"
        ((ERROR_COUNT++))
    fi

    info "Chart: ${chart_name} v${chart_version}"
    return 0
}

# Helm lint 실행
run_helm_lint() {
    local chart_path="$1"

    info "Running helm lint..."

    local lint_args=("lint" "${chart_path}")

    if [[ -n "${VALUES_FILE}" ]]; then
        lint_args+=("-f" "${VALUES_FILE}")
    fi

    if [[ "${STRICT_MODE}" == "true" ]]; then
        lint_args+=("--strict")
    fi

    local lint_output
    local lint_exit_code=0

    lint_output=$(helm "${lint_args[@]}" 2>&1) || lint_exit_code=$?

    echo "${lint_output}"

    if [[ $lint_exit_code -eq 0 ]]; then
        LINT_PASSED="true"
        info "Helm lint passed"
    else
        error "Helm lint failed"
        ((ERROR_COUNT++))

        # 경고 수 계산
        local warn_count
        warn_count=$(echo "${lint_output}" | grep -c "\[WARNING\]" || echo 0)
        WARNING_COUNT=$((WARNING_COUNT + warn_count))
    fi

    return $lint_exit_code
}

# Helm template 렌더링
run_helm_template() {
    local chart_path="$1"

    info "Running helm template..."

    local template_args=("template" "test-release" "${chart_path}")

    if [[ -n "${VALUES_FILE}" ]]; then
        template_args+=("-f" "${VALUES_FILE}")
    fi

    if [[ -n "${KUBE_VERSION}" ]]; then
        template_args+=("--kube-version" "${KUBE_VERSION}")
    fi

    local template_output
    local template_exit_code=0

    template_output=$(helm "${template_args[@]}" 2>&1) || template_exit_code=$?

    if [[ $template_exit_code -eq 0 ]]; then
        TEMPLATE_PASSED="true"
        info "Helm template rendering passed"

        # 출력 디렉토리가 지정된 경우 저장
        if [[ -n "${OUTPUT_DIR}" ]]; then
            mkdir -p "${OUTPUT_DIR}"
            echo "${template_output}" > "${OUTPUT_DIR}/rendered-manifests.yaml"
            info "Rendered manifests saved to: ${OUTPUT_DIR}/rendered-manifests.yaml"
        fi

        # 렌더링된 리소스 요약
        local resource_count
        resource_count=$(echo "${template_output}" | grep -c "^kind:" || echo 0)
        info "Rendered ${resource_count} Kubernetes resources"

        # 리소스 종류별 카운트
        if [[ "${VERBOSE}" == "true" ]]; then
            echo "${template_output}" | grep "^kind:" | sort | uniq -c
        fi
    else
        error "Helm template rendering failed"
        echo "${template_output}" >&2
        ((ERROR_COUNT++))
    fi

    return $template_exit_code
}

# 베스트 프랙티스 검증
check_best_practices() {
    local chart_path="$1"

    info "Checking best practices..."

    # values.yaml 검사
    if [[ -f "${chart_path}/values.yaml" ]]; then
        # 리소스 제한 설정 확인
        if ! grep -q "resources:" "${chart_path}/values.yaml" 2>/dev/null; then
            warn "No resource limits defined in values.yaml"
            ((WARNING_COUNT++))
        fi

        # 보안 컨텍스트 확인
        if ! grep -q "securityContext:" "${chart_path}/values.yaml" 2>/dev/null; then
            warn "No securityContext defined in values.yaml"
            ((WARNING_COUNT++))
        fi
    fi

    # templates 검사
    if [[ -d "${chart_path}/templates" ]]; then
        # _helpers.tpl 존재 확인
        if [[ ! -f "${chart_path}/templates/_helpers.tpl" ]]; then
            warn "No _helpers.tpl found (recommended for reusable templates)"
            ((WARNING_COUNT++))
        fi

        # NOTES.txt 존재 확인
        if [[ ! -f "${chart_path}/templates/NOTES.txt" ]]; then
            log "No NOTES.txt found (optional)"
        fi
    fi
}

# 결과 요약 출력
print_summary() {
    echo ""
    echo "================================================================================"
    echo "Helm 검증 결과 요약"
    echo "================================================================================"
    echo "차트 경로: ${CHART_PATH}"
    echo ""
    echo "검증 결과:"
    echo "  - Lint:     $([[ "${LINT_PASSED}" == "true" ]] && echo "PASSED" || echo "FAILED")"
    echo "  - Template: $([[ "${TEMPLATE_PASSED}" == "true" ]] && echo "PASSED" || echo "FAILED")"
    echo ""
    echo "이슈:"
    echo "  - Errors:   ${ERROR_COUNT}"
    echo "  - Warnings: ${WARNING_COUNT}"
    echo "================================================================================"
}

# GitHub Actions 출력
set_github_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "lint_passed=${LINT_PASSED}"
            echo "template_passed=${TEMPLATE_PASSED}"
            echo "error_count=${ERROR_COUNT}"
            echo "warning_count=${WARNING_COUNT}"
        } >> "$GITHUB_OUTPUT"
    fi
}

# =============================================================================
# 메인 실행
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--values)       VALUES_FILE="$2"; shift 2 ;;
            -o|--output)       OUTPUT_DIR="$2"; shift 2 ;;
            --strict)          STRICT_MODE="true"; shift ;;
            --kube-version)    KUBE_VERSION="$2"; shift 2 ;;
            -v|--verbose)      VERBOSE="true"; shift ;;
            -h|--help)         usage; exit 0 ;;
            --version)         echo "v${VERSION}"; exit 0 ;;
            -*)                error "Unknown option: $1"; usage; exit 2 ;;
            *)                 CHART_PATH="$1"; shift ;;
        esac
    done

    if [[ -z "${CHART_PATH}" ]]; then
        error "Chart path is required"
        usage
        exit 2
    fi

    if [[ ! -d "${CHART_PATH}" ]]; then
        error "Chart directory not found: ${CHART_PATH}"
        exit 2
    fi

    CHART_PATH="$(cd "${CHART_PATH}" && pwd)"

    # Helm 확인
    check_helm

    # 검증 실행
    validate_chart_structure "${CHART_PATH}" || true
    run_helm_lint "${CHART_PATH}" || true
    run_helm_template "${CHART_PATH}" || true
    check_best_practices "${CHART_PATH}"

    # 결과 출력
    print_summary
    set_github_output

    # 종료 코드 결정
    if [[ ${ERROR_COUNT} -gt 0 ]]; then
        exit 1
    fi

    if [[ "${STRICT_MODE}" == "true" && ${WARNING_COUNT} -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
