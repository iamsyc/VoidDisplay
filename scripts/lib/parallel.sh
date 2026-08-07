#!/usr/bin/env bash

if [[ -z "${VOIDDISPLAY_PARALLEL_SH_SOURCED:-}" ]]; then
	VOIDDISPLAY_PARALLEL_SH_SOURCED=1
	PARALLEL_GROUP_ACTIVE="false"

	# shellcheck source=scripts/lib/common.sh
	source "$TOOL_ROOT/scripts/lib/common.sh"

	parallel_group_begin() {
		[[ "$PARALLEL_GROUP_ACTIVE" == "false" ]] ||
			die "Cannot start a new parallel group while another group is active."
		PARALLEL_JOB_NAMES=()
		PARALLEL_JOB_LOGS=()
		PARALLEL_JOB_PIDS=()
		PARALLEL_JOB_STATUSES=()
		PARALLEL_GROUP_ACTIVE="true"
	}

	parallel_group_start_with_mode() {
		local output_mode="$1"
		local name="$2"
		local log_path="$3"
		shift 3
		local pipeline_statuses=()
		local command_status
		local tee_status

		[[ -n "$name" ]] || die "Parallel job name is required."
		[[ -n "$log_path" ]] || die "Parallel job log path is required."
		[[ "$#" -gt 0 ]] || die "Parallel job command is required: $name"

		mkdir -p "$(dirname "$log_path")"
		info "Starting parallel job: $name"
		case "$output_mode" in
		buffered)
			(
				"$@"
			) >"$log_path" 2>&1 &
			;;
		streamed)
			(
				set +e
				"$@" 2>&1 | /usr/bin/tee "$log_path"
				pipeline_statuses=("${PIPESTATUS[@]}")
				command_status="${pipeline_statuses[0]:-1}"
				tee_status="${pipeline_statuses[1]:-1}"
				if [[ "$tee_status" -ne 0 ]]; then
					exit "$tee_status"
				fi
				exit "$command_status"
			) &
			;;
		*) die "Unknown parallel output mode: $output_mode" ;;
		esac

		PARALLEL_JOB_NAMES+=("$name")
		PARALLEL_JOB_LOGS+=("$log_path")
		PARALLEL_JOB_PIDS+=("$!")
	}

	parallel_group_start() {
		parallel_group_start_with_mode buffered "$@"
	}

	parallel_group_start_streamed() {
		parallel_group_start_with_mode streamed "$@"
	}

	parallel_group_wait() {
		local label="$1"
		local index
		local status
		local failed="false"
		local first_failure_status=1

		[[ "${#PARALLEL_JOB_PIDS[@]}" -gt 0 ]] || die "Parallel group has no jobs: $label"

		for index in "${!PARALLEL_JOB_PIDS[@]}"; do
			status=0
			wait "${PARALLEL_JOB_PIDS[$index]}" || status=$?
			PARALLEL_JOB_STATUSES[index]="$status"
			if [[ "$status" -eq 0 ]]; then
				info "Parallel job passed: ${PARALLEL_JOB_NAMES[$index]}"
				continue
			fi

			if [[ "$failed" == "false" ]]; then
				first_failure_status="$status"
			fi
			failed="true"
			warn "Parallel job failed: ${PARALLEL_JOB_NAMES[$index]} status=$status log=${PARALLEL_JOB_LOGS[$index]}"
		done

		if [[ "$failed" == "true" ]]; then
			for index in "${!PARALLEL_JOB_PIDS[@]}"; do
				if [[ -f "${PARALLEL_JOB_LOGS[$index]}" ]]; then
					printf '[INFO] Last output from %s:\n' "${PARALLEL_JOB_NAMES[$index]}" >&2
					tail -n 40 "${PARALLEL_JOB_LOGS[$index]}" >&2
				fi
			done
			PARALLEL_GROUP_ACTIVE="false"
			return "$first_failure_status"
		fi

		PARALLEL_GROUP_ACTIVE="false"
		info "Parallel group passed: $label"
	}

	parallel_descendant_pids() {
		local parent_pid="$1"
		local child_pid

		while IFS= read -r child_pid; do
			[[ "$child_pid" =~ ^[0-9]+$ ]] || continue
			parallel_descendant_pids "$child_pid"
			printf '%s\n' "$child_pid"
		done < <(/usr/bin/pgrep -P "$parent_pid" 2>/dev/null || true)
	}

	parallel_process_is_active() {
		local pid="$1"
		local state

		/bin/kill -0 "$pid" >/dev/null 2>&1 || return 1
		state="$(/bin/ps -o state= -p "$pid" 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
		[[ -n "$state" && "$state" != "Z" ]]
	}

	parallel_stop_process_tree() {
		local root_pid="$1"
		local signal_name="${2:-TERM}"
		local descendant_pid
		local target_pid
		local attempt
		local targets=()
		local alive="false"

		while IFS= read -r descendant_pid; do
			[[ -n "$descendant_pid" ]] && targets+=("$descendant_pid")
		done < <(parallel_descendant_pids "$root_pid")
		targets+=("$root_pid")
		/bin/kill -"$signal_name" "${targets[@]}" >/dev/null 2>&1 || true
		for attempt in $(seq 1 20); do
			alive="false"
			for target_pid in "${targets[@]}"; do
				if parallel_process_is_active "$target_pid"; then
					alive="true"
					break
				fi
			done
			[[ "$alive" == "true" ]] || break
			/bin/sleep 0.1
		done
		if [[ "$alive" == "true" ]]; then
			while IFS= read -r descendant_pid; do
				[[ -n "$descendant_pid" ]] && targets+=("$descendant_pid")
			done < <(parallel_descendant_pids "$root_pid")
			/bin/kill -KILL "${targets[@]}" >/dev/null 2>&1 || true
		fi
		wait "$root_pid" >/dev/null 2>&1 || true
	}

	parallel_group_cancel() {
		local pid

		[[ "$PARALLEL_GROUP_ACTIVE" == "true" ]] || return 0
		warn "Stopping active parallel jobs."
		for pid in "${PARALLEL_JOB_PIDS[@]}"; do
			parallel_stop_process_tree "$pid"
		done
		PARALLEL_GROUP_ACTIVE="false"
	}

	parallel_job_status() {
		local name="$1"
		local index

		for index in "${!PARALLEL_JOB_NAMES[@]}"; do
			if [[ "${PARALLEL_JOB_NAMES[$index]}" == "$name" ]]; then
				[[ -n "${PARALLEL_JOB_STATUSES[$index]+set}" ]] ||
					die "Parallel job has not completed: $name"
				printf '%s\n' "${PARALLEL_JOB_STATUSES[$index]}"
				return
			fi
		done
		die "Unknown parallel job: $name"
	}
fi
