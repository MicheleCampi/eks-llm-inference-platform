# A-024 evidence: the vLLM CPU v0.20 step on Sapphire Rapids is in vLLM, not in torch / oneDNN (2026-11-22)

Follow-up of [A-023](bisect-a023-2026-11-22.md). A-023 found the steady-state
step between v0.19.1 (p50 3.785 s) and v0.20.2 (5.725 s) on an Intel Xeon
Platinum 8488C. v0.20.0 is the release where the vLLM CPU image moves from
torch 2.10.0 (oneDNN 3.7.1) to torch 2.11.0 (oneDNN 3.10.2). This session
separates torch from vLLM on the same CPU.

- **Budget:** A-024, with a ceiling of 0,50 EUR and at most 1,5 h. Michele approved it at 19:43Z. The re-run was approved at 20:24Z, inside the same ceiling.
- **Machine:** one EC2 `m7i-flex.large` On-Demand in eu-west-1a, as in A-023. Its CPU is an Intel Xeon Platinum 8488C, 2 vCPUs, with `amx_bf16` and `avx512f`. It ran in the default VPC with no inbound port.
- **Software:** Amazon Linux 2023 `ami-04060762724eee84a`, Docker. Scripts are in `vllm-coldstart-operator` `hack/sapphire-bisect/` on the study branch:
  - `a024.sh` drives the session;
  - `matmul.py` is the torch-only timing;
  - `user-data-a024.sh` runs it all and powers the instance off.
- **The two measures:**
  1. `matmul.py` runs with the `python3` and torch of each image, so no vLLM code is involved:
     - a bf16 `torch.nn.Linear` at the decode shapes of Qwen2.5-0.5B (qkv 896→1152, o 896→896, gate_up 896→9728, down 4864→896, each × 24 layers, plus lm_head 896→151936);
     - M = 1 and M = 4 rows, 1 and 2 threads, on cpu0 and its SMT sibling;
     - the median time of each shape, summed per token;
     - the oneDNN kernel recorded with `ONEDNN_VERBOSE=1`.
  2. The A-023 steady-state measure (`steady-study/study.sh`) for v0.19.1 and v0.20.0 in the same session, 2 runs each:
     - eager, `--cpuset-cpus 0,1`, 6 GiB, `VLLM_CPU_KVCACHE_SPACE=1`;
     - the operator v0.17.0 warmup;
     - 40 requests of the game day probe (32 tokens);
     - the first probe request excluded from p50 and p95.
- **Images by digest:**
  - v0.19.1 `vllm/vllm-openai-cpu@sha256:4c697ae650eb…`
  - v0.20.0 `vllm/vllm-openai-cpu@sha256:dc28ea3382c4…`
- **Roles:** Michele was the operator and ran every command. The AI agent wrote the scripts, the commands and this evidence.

## Result

| | v0.19.1 | v0.20.0 | Change |
|---|---|---|---|
| torch / oneDNN | 2.10.0 / v3.7.1 | 2.11.0 / v3.10.2 | |
| oneDNN kernel (gate_up, M=1) | `brg_matmul:avx10_1_512_amx` | `brg_matmul:avx10_1_512_amx` | same |
| torch linear per token, M=1, 1 thread | 77.36 ms | 77.98 ms | +0.8 % |
| torch linear per token, M=1, 2 threads | 83.18 ms | 83.80 ms | +0.7 % |
| torch linear per token, M=4, 1 thread | 83.15 ms | 85.43 ms | +2.7 % |
| torch linear per token, M=4, 2 threads | 83.99 ms | 84.11 ms | +0.1 % |
| vLLM steady p50, rep 1 / rep 2 | 3.84 / 3.85 s | 6.10 / 6.03 s | |
| **vLLM steady p50 (median)** | **3.845 s** | **6.065 s** | **+58 %** |
| Ready | 30, 35 s | 70, 70 s | |

All 160 measured requests answered HTTP 200 (4 runs × 40).

- **The step is already in v0.20.0**, the first release of the 0.20 minor. v0.20.1 was not needed.
- **torch and oneDNN are ruled out as the cause.** With the torch of each image, the same linear layers at the same shapes take the same time, within 3 %. The oneDNN kernel is the same AMX one.
- **The extra time is in vLLM.** Per generated token:
  - v0.19.1 takes about 120 ms (3.845 s / 32 tokens);
  - v0.20.0 takes about 190 ms;
  - torch's linear layers alone cost about 77 ms in both.

  v0.20.0 adds about 70 ms per token somewhere in vLLM's own CPU path, for example in how the linear layers are dispatched, the CPU attention backend, sampling or scheduling. Which one is not measured here.
- **v0.19.1 matches A-023** (3.845 s against 3.785 s, +1.6 %), on a fresh instance.
- **The same direction shows on AMD EPYC 7763 too**, in the dry run on a GitHub runner (operator run 45062201102, 1 run each, not the result): v0.19.1 4.25 s, v0.20.0 4.97 s (+17 %), Ready 40 s → 201 s. On that runner torch has no oneDNN bf16 path (`mkldnn_bf16: false`), so its matmul says nothing about AMX.

## Process notes

- **The first run lost its results.** Instance `i-05e56b5c66a15cd2d` ran from 20:00:04Z to 20:21Z. When an instance terminates, the console output read with `--latest` gets cut. The monitor command then overwrote its file with the short output. The full console (without `--latest`) stopped at 136 s of boot. Only the v0.19.1 numbers came back from that run; they match the re-run:
  - matmul 76.66 ms per token at M=1, 1 thread;
  - p50 3.725 s.
- **Fix before the re-run** (study branch commit `dbaf325`):
  - the user-data repeats every result line as `A024 SUMMARY` and waits 4 min before power-off;
  - the new monitor only appends new lines to its file.
- **Re-run:** instance `i-0b9c5a00fc48a534a`, launched at 20:24:45Z, powered itself off at 20:50:10Z. Checked by Michele at 20:54Z: no instance or volume tagged `Session=A-024` left (0 and 0), and `verify-teardown.sh` gives TEARDOWN CLEAN. It was tagged `Session=A-024` and also `Project=eks-llm-inference-platform`, so `scripts/verify-teardown.sh` sees it.
- **The 40 min estimate was too large.** One session takes about 21 min plus the 4 min wait.

## Raw lines (re-run)

    A024 cpu: Intel(R) Xeon(R) Platinum 8488C, 2 vcpus, cpuset 0-1, amx_bf16,avx512f
    A024 matmul v0.19.1 t1 {"info": {"torch": "2.10.0+cpu", "onednn": "MKL-DNN v3.7.1", "mkldnn_available": true, "mkldnn_bf16": true, "threads": 1}}
    A024 matmul v0.19.1 t1 {"m": 1, "per_token_linear_ms": 77.36, "torch": "2.10.0+cpu", "threads": 1}
    A024 matmul v0.19.1 t1 {"m": 4, "per_token_linear_ms": 83.15, "torch": "2.10.0+cpu", "threads": 1}
    A024 matmul v0.19.1 t2 {"m": 1, "per_token_linear_ms": 83.18, "torch": "2.10.0+cpu", "threads": 2}
    A024 matmul v0.19.1 t2 {"m": 4, "per_token_linear_ms": 83.99, "torch": "2.10.0+cpu", "threads": 2}
    A024 onednn v0.19.1: 3 exec,cpu,matmul,brg_matmul:avx10_1_512_amx
    A024 run v0.19.1 rep 1: p50 p95 first ready n failed = 3.84 3.9 3.85 30 40 0
    A024 run v0.19.1 rep 2: p50 p95 first ready n failed = 3.85 3.89 3.86 35 40 0
    A024 v0.19.1 p50 3.845
    A024 matmul v0.20.0 t1 {"info": {"torch": "2.11.0+cpu", "onednn": "MKL-DNN v3.10.2", "mkldnn_available": true, "mkldnn_bf16": true, "threads": 1}}
    A024 matmul v0.20.0 t1 {"m": 1, "per_token_linear_ms": 77.98, "torch": "2.11.0+cpu", "threads": 1}
    A024 matmul v0.20.0 t1 {"m": 4, "per_token_linear_ms": 85.43, "torch": "2.11.0+cpu", "threads": 1}
    A024 matmul v0.20.0 t2 {"m": 1, "per_token_linear_ms": 83.8, "torch": "2.11.0+cpu", "threads": 2}
    A024 matmul v0.20.0 t2 {"m": 4, "per_token_linear_ms": 84.11, "torch": "2.11.0+cpu", "threads": 2}
    A024 onednn v0.20.0: 3 exec,cpu,matmul,brg_matmul:avx10_1_512_amx
    A024 run v0.20.0 rep 1: p50 p95 first ready n failed = 6.1 6.28 6.06 70 40 0
    A024 run v0.20.0 rep 2: p50 p95 first ready n failed = 6.03 6.16 5.97 70 40 0
    A024 v0.20.0 p50 6.065
    A024 DONE

Saved by Michele on optim-dev as `~/eks/a024r.txt`.

## Next steps

1. **Read the v0.19.1 → v0.20.0 changes to the CPU path** (free): release notes and the commits touching `csrc/cpu`, the CPU attention backend, `vllm/platforms/cpu.py`, the CPU worker and model runner, and how linear layers are dispatched on CPU. The 30 s → 70 s Ready jump suggests something at load time too.
2. **The upstream issue for vllm-project/vllm** (`[Performance]: CPU backend ~1.5x slower decode on Sapphire Rapids since v0.20.0`), with:
   - the A-023 and A-024 tables, the digests and `lscpu`;
   - the reproduction script;
   - the torch-only control.

   Michele reads it before it is published, AI assistance is declared, and maintainer replies are in his own words.
