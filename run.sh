#!/usr/bin/env bash
# Launch the Xenium+CODEX integration workflow.
#
#   ./run.sh dry     # dry run: print the plan (no jobs submitted, nothing runs)
#   ./run.sh run     # submit one SLURM job per step, in order; this shell is the
#                    #   orchestrator, so keep it alive (tmux/screen) until done
#   ./run.sh submit  # same as run, but the orchestrator itself runs as a small
#                    #   SLURM job, so you can log out
#   ./run.sh dag     # write dag.svg (or dag.dot) of the step graph
#   ./run.sh unlock  # release a stale .snakemake lock after a killed run
#
# Config: config/config.yaml (a copy of config/config.example.yaml).
# Any other options are passed on to Snakemake, e.g.  ./run.sh dry --forceall
#
# Snakemake is taken from $SNAKEMAKE if set, else `snakemake` on PATH (activated
# snakemake_env), else `micromamba run -n snakemake_env snakemake`.
# dry/run/submit use --rerun-triggers mtime: a step reruns only when its inputs are
# newer than its outputs, so editing a config comment or path does not redo steps.
# submit writes the orchestrator log to <results_dir>/logs/orchestrator_<jobid>.log;
# set SBATCH_PARTITION / SBATCH_ACCOUNT if your cluster needs them.
set -euo pipefail

module load stack/2024-06 gcc/12.2.0 python/3.11.6
export PATH="$HOME/.local/bin:$PATH"       # where `pip install --user` puts snakemake

cd "$(dirname "$0")"                       # workflow dir (holds Snakefile + config.yaml)
PROFILE=profiles/slurm
MODE="${1:-dry}"

# First run on a new account: install snakemake + the SLURM executor plugin into
# ~/.local. Skipped on every later run.
if ! command -v snakemake >/dev/null 2>&1 || \
   ! python3 -c 'import snakemake_executor_plugin_slurm' >/dev/null 2>&1; then
  echo "[run.sh] installing snakemake into ~/.local (one-time, takes a minute)"
  module load eth_proxy 2>/dev/null || true   # outbound network for pip
  python3 -m pip install --user --quiet \
    snakemake snakemake-executor-plugin-slurm  # pin as 'snakemake>=8,<9' if v9 breaks
  hash -r
  command -v snakemake >/dev/null || { echo "ERROR: install failed"; exit 1; }
  echo "[run.sh] installed snakemake $(snakemake --version)"
fi

# -----------------------------------------------------------------------------
case "$MODE" in
    dry)   # with the profile, so the plan shows the partitions a real run would use
        "${SMK[@]}" -n -p --workflow-profile "$PROFILE" --rerun-triggers mtime "$@"
        ;;
    run)
        "${SMK[@]}" --workflow-profile "$PROFILE" --rerun-triggers mtime "$@"
        ;;
    submit)
        RESULTS=$(results_dir "$CONFIG")
        [ -n "$RESULTS" ] || { echo "no paths.results_dir in $CONFIG" >&2; exit 1; }
        LOGDIR=$(readlink -m "$RESULTS/logs")
        mkdir -p "$LOGDIR"
        # The orchestrator only waits and submits; the steps get their own jobs.
        # --time must outlive the whole pipeline (all steps + queue waits).
        JOB=$(sbatch --parsable \
            --job-name=smk_orchestrator \
            --output="$LOGDIR/orchestrator_%j.log" \
            --time=48:00:00 --ntasks=1 --cpus-per-task=1 --mem-per-cpu=2G \
            --wrap="$(printf '%q ' "$REPO/run.sh" run "$@")")
        echo "submitted orchestrator job $JOB (log: $LOGDIR/orchestrator_$JOB.log)"
        echo "watch the step jobs with: squeue -u $USER"
        ;;
    dag)
        if command -v dot > /dev/null; then
            "${SMK[@]}" --dag "$@" | dot -Tsvg > dag.svg
            echo "wrote dag.svg"
        else
            "${SMK[@]}" --dag "$@" > dag.dot
            echo "graphviz 'dot' not found; wrote dag.dot instead"
        fi
        ;;
    unlock)
        "${SMK[@]}" --unlock "$@"
        ;;
    *)
        echo "usage: $0 {dry|run|submit|dag|unlock} [--configfile FILE] [snakemake options]" >&2
        exit 1
        ;;
esac
