#!/bin/bash
# =============================================================================
# CRaC 호환성 정적 분석 스크립트
# =============================================================================
# Java 소스 코드에서 CRaC(Coordinated Restore at Checkpoint) 비호환 패턴을 검출합니다.
#
# 사용법: ./check-crac-compatibility.sh [OPTIONS] <source_directory>
# =============================================================================

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# 설정 변수
# -----------------------------------------------------------------------------
SOURCE_DIR=""
OUTPUT_FORMAT="text"           # text, json, markdown
OUTPUT_FILE=""
FAIL_ON_ERROR="true"
FAIL_ON_WARNING="false"
EXCLUDE_DIRS="test,tests,build,target,node_modules,.git"
VERBOSE="false"
MIN_JAVA_VERSION="17"

# 카운터
ERROR_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0

# 결과 저장
declare -a FINDINGS=()

# =============================================================================
# CRaC 비호환 패턴 정의
# =============================================================================
# 형식: "SEVERITY|CATEGORY|PATTERN|DESCRIPTION|RECOMMENDATION"

declare -a PATTERNS=(
    # -------------------------------------------------------------------------
    # 리소스 관련 (ERROR) - checkpoint 시 파일/네트워크 핸들 손실
    # -------------------------------------------------------------------------
    "ERROR|RESOURCE|new FileInputStream|FileInputStream 직접 생성 - checkpoint 시 파일 핸들 손실|Resource 인터페이스 구현하여 beforeCheckpoint()에서 close"
    "ERROR|RESOURCE|new FileOutputStream|FileOutputStream 직접 생성 - checkpoint 시 파일 핸들 손실|Resource 인터페이스 구현하여 beforeCheckpoint()에서 close"
    "ERROR|RESOURCE|new RandomAccessFile|RandomAccessFile 직접 생성|Resource 인터페이스로 파일 접근 관리"
    "ERROR|RESOURCE|new Socket\s*\(|Socket 직접 생성 - checkpoint 시 연결 끊김|Resource 인터페이스로 연결 관리 또는 지연 연결 패턴"
    "ERROR|RESOURCE|new ServerSocket|ServerSocket 직접 생성 - checkpoint 시 바인딩 손실|Resource 인터페이스로 서버 소켓 관리"
    "ERROR|RESOURCE|static.*Connection\s+\w+|JDBC Connection 정적 필드 - restore 후 연결 무효화|Connection Pool 사용 또는 Resource 인터페이스"
    "ERROR|RESOURCE|static.*DataSource|DataSource 정적 필드|afterRestore()에서 connection pool 재초기화"

    # -------------------------------------------------------------------------
    # 스레드 관련 (ERROR/WARNING)
    # -------------------------------------------------------------------------
    "ERROR|THREAD|new Thread\s*\(|Thread 직접 생성 - checkpoint 시 스레드 상태 비결정적|ExecutorService 사용, Resource로 관리"
    "ERROR|THREAD|\.start\s*\(\s*\)|Thread.start() 호출 - 실행 중인 스레드는 checkpoint 불가|스레드 생명주기를 Resource로 관리"
    "WARNING|THREAD|ThreadLocal|ThreadLocal 사용 - restore 후 상태 손실 가능|afterRestore()에서 재설정 필요"
    "WARNING|THREAD|ScheduledExecutorService|ScheduledExecutorService - 스케줄 타이밍 문제|afterRestore()에서 스케줄 재설정"

    # -------------------------------------------------------------------------
    # 네이티브 관련 (ERROR)
    # -------------------------------------------------------------------------
    "ERROR|NATIVE|native\s+\w+\s+\w+\s*\(|JNI native 메서드 - 네이티브 상태 복원 불가|순수 Java 대안 사용 또는 Resource로 상태 관리"
    "ERROR|NATIVE|System\.loadLibrary|네이티브 라이브러리 로드|afterRestore()에서 재초기화 필요"
    "ERROR|NATIVE|System\.load\s*\(|네이티브 라이브러리 직접 로드|afterRestore()에서 재초기화 필요"
    "WARNING|NATIVE|com\.sun\.jna|JNA 사용 - 네이티브 호출 문제 가능|JNA 호출 결과 유효성 검토"

    # -------------------------------------------------------------------------
    # 초기화 관련 (WARNING)
    # -------------------------------------------------------------------------
    "WARNING|INIT|static\s*\{.*new\s+(File|Socket)|static 블록에서 리소스 할당|지연 초기화 또는 afterRestore()에서 초기화"
    "WARNING|INIT|@PostConstruct|@PostConstruct 사용 - 빈 초기화 시점 주의|SmartLifecycle 또는 Resource 인터페이스 고려"

    # -------------------------------------------------------------------------
    # 시간/보안 관련 (WARNING)
    # -------------------------------------------------------------------------
    "WARNING|TIME|static.*System\.currentTimeMillis|currentTimeMillis 정적 캐싱 - restore 후 시간 불일치|동적 시간 조회 또는 afterRestore()에서 갱신"
    "WARNING|TIME|static.*System\.nanoTime|nanoTime 정적 캐싱|동적 시간 조회"
    "WARNING|TIME|static.*Instant\.now|Instant.now 정적 캐싱|동적 시간 조회"
    "WARNING|SECURITY|static.*SecureRandom|SecureRandom 정적 초기화 - 엔트로피 문제|afterRestore()에서 reseed"

    # -------------------------------------------------------------------------
    # CRaC 호환성 확인 (INFO - 긍정적)
    # -------------------------------------------------------------------------
    "INFO|CRAC_API|implements.*Resource|CRaC Resource 인터페이스 구현됨|CRaC 호환성 확보"
    "INFO|CRAC_API|beforeCheckpoint|beforeCheckpoint 메서드 구현됨|checkpoint 전 리소스 정리 로직"
    "INFO|CRAC_API|afterRestore|afterRestore 메서드 구현됨|restore 후 리소스 복구 로직"
)

# =============================================================================
# 함수 정의
# =============================================================================

usage() {
    cat << EOF
CRaC 호환성 정적 분석기 v${VERSION}

사용법: $0 [OPTIONS] <source_directory>

OPTIONS:
  -o, --output <file>       결과를 파일로 출력
  -f, --format <format>     출력 형식: text, json, markdown (기본: text)
  --fail-on-error          ERROR 발견 시 exit 1 (기본: true)
  --no-fail-on-error       ERROR가 있어도 exit 0
  --fail-on-warning        WARNING 발견 시에도 exit 1
  --min-java-version <ver> 최소 Java 버전 (기본: 17)
  --exclude-dirs <dirs>    제외 디렉토리 (콤마 구분)
  -v, --verbose            상세 로그
  -h, --help               도움말

심각도:
  ERROR   - CRaC checkpoint/restore 실패 가능성 높음
  WARNING - 잠재적 문제, 검토 필요
  INFO    - 참고 (CRaC API 사용 등 긍정적 패턴 포함)

예제:
  $0 ./src/main/java
  $0 -f markdown -o report.md ./src
  $0 --fail-on-warning ./src/main/java

EOF
}

log() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

error() {
    echo "[ERROR] $*" >&2
}

# Java 버전 확인
check_java_version() {
    local source_dir="$1"
    local java_version=""

    # pom.xml에서 Java 버전 확인
    if [[ -f "${source_dir}/pom.xml" ]] || [[ -f "${source_dir}/../pom.xml" ]]; then
        local pom_file
        if [[ -f "${source_dir}/pom.xml" ]]; then
            pom_file="${source_dir}/pom.xml"
        else
            pom_file="${source_dir}/../pom.xml"
        fi

        java_version=$(grep -oP '(?<=<java.version>)[^<]+' "$pom_file" 2>/dev/null || \
                       grep -oP '(?<=<maven.compiler.source>)[^<]+' "$pom_file" 2>/dev/null || \
                       echo "")
    fi

    # build.gradle에서 Java 버전 확인
    if [[ -z "$java_version" ]]; then
        local gradle_file=""
        if [[ -f "${source_dir}/build.gradle" ]]; then
            gradle_file="${source_dir}/build.gradle"
        elif [[ -f "${source_dir}/../build.gradle" ]]; then
            gradle_file="${source_dir}/../build.gradle"
        elif [[ -f "${source_dir}/build.gradle.kts" ]]; then
            gradle_file="${source_dir}/build.gradle.kts"
        elif [[ -f "${source_dir}/../build.gradle.kts" ]]; then
            gradle_file="${source_dir}/../build.gradle.kts"
        fi

        if [[ -n "$gradle_file" ]]; then
            java_version=$(grep -oP "(?<=sourceCompatibility\s*=\s*['\"]?)[0-9]+" "$gradle_file" 2>/dev/null || \
                          grep -oP "(?<=JavaVersion\.VERSION_)[0-9]+" "$gradle_file" 2>/dev/null || \
                          echo "")
        fi
    fi

    if [[ -n "$java_version" ]]; then
        # 버전 정규화 (1.8 -> 8, 17 -> 17)
        java_version=$(echo "$java_version" | sed 's/^1\.//')

        if [[ "$java_version" -lt "$MIN_JAVA_VERSION" ]]; then
            FINDINGS+=("ERROR|JAVA_VERSION|build config|0|Java ${java_version}|Java ${java_version} 사용 중 - CRaC는 Java ${MIN_JAVA_VERSION}+ 필요|Java ${MIN_JAVA_VERSION} 이상으로 업그레이드")
            ((ERROR_COUNT++))
        else
            FINDINGS+=("INFO|JAVA_VERSION|build config|0|Java ${java_version}|Java ${java_version} - CRaC 지원 버전|")
            ((INFO_COUNT++))
        fi
    fi
}

# CRaC 의존성 확인
check_crac_dependency() {
    local source_dir="$1"
    local has_crac_dep="false"

    # pom.xml 확인
    if [[ -f "${source_dir}/pom.xml" ]] || [[ -f "${source_dir}/../pom.xml" ]]; then
        local pom_file
        if [[ -f "${source_dir}/pom.xml" ]]; then
            pom_file="${source_dir}/pom.xml"
        else
            pom_file="${source_dir}/../pom.xml"
        fi

        if grep -q "crac" "$pom_file" 2>/dev/null; then
            has_crac_dep="true"
        fi
    fi

    # build.gradle 확인
    local gradle_files=("${source_dir}/build.gradle" "${source_dir}/../build.gradle"
                        "${source_dir}/build.gradle.kts" "${source_dir}/../build.gradle.kts")
    for gradle_file in "${gradle_files[@]}"; do
        if [[ -f "$gradle_file" ]] && grep -q "crac" "$gradle_file" 2>/dev/null; then
            has_crac_dep="true"
            break
        fi
    done

    if [[ "$has_crac_dep" == "true" ]]; then
        FINDINGS+=("INFO|DEPENDENCY|build config|0|CRaC dependency found|CRaC API 의존성 포함됨|")
        ((INFO_COUNT++))
    else
        FINDINGS+=("WARNING|DEPENDENCY|build config|0|No CRaC dependency|CRaC API 의존성 없음 - Resource 인터페이스 사용 불가|org.crac:crac 의존성 추가 권장")
        ((WARNING_COUNT++))
    fi
}

# 파일 분석
analyze_file() {
    local file="$1"
    local relative_path="${file#${SOURCE_DIR}/}"

    log "Analyzing: ${relative_path}"

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))

        # 주석 라인 스킵
        local trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        if [[ "$trimmed" == "//"* ]] || [[ "$trimmed" == "*"* ]]; then
            continue
        fi

        for pattern_def in "${PATTERNS[@]}"; do
            IFS='|' read -r severity category pattern description recommendation <<< "${pattern_def}"

            if echo "$line" | grep -qE "$pattern"; then
                local trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 100)

                FINDINGS+=("${severity}|${category}|${relative_path}|${line_num}|${trimmed_line}|${description}|${recommendation}")

                case "$severity" in
                    ERROR)   ((ERROR_COUNT++)) ;;
                    WARNING) ((WARNING_COUNT++)) ;;
                    INFO)    ((INFO_COUNT++)) ;;
                esac
            fi
        done
    done < "$file"
}

# 디렉토리 분석
analyze_directory() {
    local dir="$1"

    # exclude 패턴 생성
    local exclude_args=""
    IFS=',' read -ra EXCLUDE_ARRAY <<< "${EXCLUDE_DIRS}"
    for exclude in "${EXCLUDE_ARRAY[@]}"; do
        exclude_args="${exclude_args} -not -path '*/${exclude}/*'"
    done

    local find_cmd="find '${dir}' -name '*.java' -type f ${exclude_args}"

    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            analyze_file "$file"
        fi
    done < <(eval "$find_cmd" 2>/dev/null)
}

# 텍스트 리포트 생성
generate_text_report() {
    cat << EOF
================================================================================
CRaC 호환성 정적 분석 리포트
================================================================================
분석 대상: ${SOURCE_DIR}
분석 일시: $(date '+%Y-%m-%d %H:%M:%S')
분석기 버전: ${VERSION}

--------------------------------------------------------------------------------
요약
--------------------------------------------------------------------------------
  ERROR:   ${ERROR_COUNT} 건
  WARNING: ${WARNING_COUNT} 건
  INFO:    ${INFO_COUNT} 건
  총계:    $((ERROR_COUNT + WARNING_COUNT + INFO_COUNT)) 건

EOF

    if [[ ${#FINDINGS[@]} -eq 0 ]]; then
        echo "CRaC 비호환 패턴이 발견되지 않았습니다."
        return
    fi

    for severity in ERROR WARNING INFO; do
        local findings_for_severity=()

        for finding in "${FINDINGS[@]}"; do
            IFS='|' read -r sev category file line code desc rec <<< "${finding}"
            if [[ "$sev" == "$severity" ]]; then
                findings_for_severity+=("${finding}")
            fi
        done

        if [[ ${#findings_for_severity[@]} -gt 0 ]]; then
            echo "================================================================================"
            echo "[${severity}]"
            echo "================================================================================"

            local idx=1
            for finding in "${findings_for_severity[@]}"; do
                IFS='|' read -r sev category file line code desc rec <<< "${finding}"
                echo ""
                echo "${idx}. [${category}] ${file}:${line}"
                echo "   코드: ${code}"
                echo "   문제: ${desc}"
                if [[ -n "$rec" ]]; then
                    echo "   권장: ${rec}"
                fi
                ((idx++))
            done
            echo ""
        fi
    done
}

# JSON 리포트 생성
generate_json_report() {
    echo "{"
    echo "  \"meta\": {"
    echo "    \"source_directory\": \"${SOURCE_DIR}\","
    echo "    \"analysis_time\": \"$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')\","
    echo "    \"version\": \"${VERSION}\""
    echo "  },"
    echo "  \"summary\": {"
    echo "    \"error_count\": ${ERROR_COUNT},"
    echo "    \"warning_count\": ${WARNING_COUNT},"
    echo "    \"info_count\": ${INFO_COUNT}"
    echo "  },"
    echo "  \"findings\": ["

    local first=true
    for finding in "${FINDINGS[@]}"; do
        IFS='|' read -r severity category file line code desc rec <<< "${finding}"

        code=$(echo "$code" | sed 's/\\/\\\\/g; s/"/\\"/g')
        desc=$(echo "$desc" | sed 's/\\/\\\\/g; s/"/\\"/g')
        rec=$(echo "$rec" | sed 's/\\/\\\\/g; s/"/\\"/g')

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo "    {"
        echo "      \"severity\": \"${severity}\","
        echo "      \"category\": \"${category}\","
        echo "      \"file\": \"${file}\","
        echo "      \"line\": ${line},"
        echo "      \"code\": \"${code}\","
        echo "      \"description\": \"${desc}\","
        echo "      \"recommendation\": \"${rec}\""
        echo -n "    }"
    done

    echo ""
    echo "  ]"
    echo "}"
}

# Markdown 리포트 생성
generate_markdown_report() {
    cat << EOF
# CRaC 호환성 정적 분석 리포트

| 항목 | 값 |
|------|-----|
| 분석 대상 | \`${SOURCE_DIR}\` |
| 분석 일시 | $(date '+%Y-%m-%d %H:%M:%S') |

## 요약

| 심각도 | 건수 | 설명 |
|--------|------|------|
| ERROR | ${ERROR_COUNT} | 필수 수정 |
| WARNING | ${WARNING_COUNT} | 검토 필요 |
| INFO | ${INFO_COUNT} | 참고 |

EOF

    if [[ ${#FINDINGS[@]} -eq 0 ]]; then
        echo "> CRaC 비호환 패턴이 발견되지 않았습니다."
        return
    fi

    for severity in ERROR WARNING INFO; do
        local findings_for_severity=()
        for finding in "${FINDINGS[@]}"; do
            IFS='|' read -r sev _ _ _ _ _ _ <<< "${finding}"
            if [[ "$sev" == "$severity" ]]; then
                findings_for_severity+=("${finding}")
            fi
        done

        if [[ ${#findings_for_severity[@]} -gt 0 ]]; then
            echo "## ${severity}"
            echo ""

            for finding in "${findings_for_severity[@]}"; do
                IFS='|' read -r sev category file line code desc rec <<< "${finding}"
                echo "### \`${file}:${line}\` [${category}]"
                echo ""
                echo "**코드:**"
                echo "\`\`\`java"
                echo "${code}"
                echo "\`\`\`"
                echo ""
                echo "**문제:** ${desc}"
                echo ""
                if [[ -n "$rec" ]]; then
                    echo "**권장:** ${rec}"
                    echo ""
                fi
                echo "---"
                echo ""
            done
        fi
    done
}

# 리포트 출력
output_report() {
    local report=""

    case "${OUTPUT_FORMAT}" in
        text)     report=$(generate_text_report) ;;
        json)     report=$(generate_json_report) ;;
        markdown) report=$(generate_markdown_report) ;;
        *)        error "Unknown format: ${OUTPUT_FORMAT}"; exit 2 ;;
    esac

    if [[ -n "${OUTPUT_FILE}" ]]; then
        echo "${report}" > "${OUTPUT_FILE}"
        echo "Report saved to: ${OUTPUT_FILE}" >&2
    else
        echo "${report}"
    fi
}

# GitHub Actions 출력
set_github_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            echo "error_count=${ERROR_COUNT}"
            echo "warning_count=${WARNING_COUNT}"
            echo "info_count=${INFO_COUNT}"
            echo "total_count=$((ERROR_COUNT + WARNING_COUNT + INFO_COUNT))"
            echo "has_errors=$([[ ${ERROR_COUNT} -gt 0 ]] && echo true || echo false)"
            echo "has_warnings=$([[ ${WARNING_COUNT} -gt 0 ]] && echo true || echo false)"
        } >> "$GITHUB_OUTPUT"
    fi
}

# =============================================================================
# 메인 실행
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)       OUTPUT_FILE="$2"; shift 2 ;;
            -f|--format)       OUTPUT_FORMAT="$2"; shift 2 ;;
            --fail-on-error)   FAIL_ON_ERROR="true"; shift ;;
            --no-fail-on-error) FAIL_ON_ERROR="false"; shift ;;
            --fail-on-warning) FAIL_ON_WARNING="true"; shift ;;
            --min-java-version) MIN_JAVA_VERSION="$2"; shift 2 ;;
            --exclude-dirs)    EXCLUDE_DIRS="$2"; shift 2 ;;
            -v|--verbose)      VERBOSE="true"; shift ;;
            -h|--help)         usage; exit 0 ;;
            --version)         echo "v${VERSION}"; exit 0 ;;
            -*)                error "Unknown option: $1"; usage; exit 2 ;;
            *)                 SOURCE_DIR="$1"; shift ;;
        esac
    done

    if [[ -z "${SOURCE_DIR}" ]]; then
        error "Source directory is required"
        usage
        exit 2
    fi

    if [[ ! -d "${SOURCE_DIR}" ]]; then
        error "Directory not found: ${SOURCE_DIR}"
        exit 2
    fi

    SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"

    log "Starting CRaC compatibility analysis..."
    log "Source: ${SOURCE_DIR}"

    # 분석 실행
    check_java_version "${SOURCE_DIR}"
    check_crac_dependency "${SOURCE_DIR}"
    analyze_directory "${SOURCE_DIR}"

    # 리포트 생성
    output_report

    # GitHub Actions 출력
    set_github_output

    # 종료 코드 결정
    local exit_code=0

    if [[ "${FAIL_ON_ERROR}" == "true" && ${ERROR_COUNT} -gt 0 ]]; then
        exit_code=1
    fi

    if [[ "${FAIL_ON_WARNING}" == "true" && ${WARNING_COUNT} -gt 0 ]]; then
        exit_code=1
    fi

    exit ${exit_code}
}

main "$@"
