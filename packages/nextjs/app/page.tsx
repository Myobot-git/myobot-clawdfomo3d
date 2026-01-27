"use client";

import { useEffect, useState } from "react";
import type { NextPage } from "next";
import { formatUnits } from "viem";
import { erc20Abi } from "viem";
import { useAccount } from "wagmi";
import { useWriteContract } from "wagmi";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

// $CLAWD token on Base
const CLAWD_TOKEN = "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07" as const;

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const [numKeys, setNumKeys] = useState<string>("1");
  const [timeLeft, setTimeLeft] = useState<string>("--:--");
  const [isApproving, setIsApproving] = useState(false);
  const [isBuying, setIsBuying] = useState(false);

  // Get the deployed ClawdFomo3D contract address
  const { data: fomo3dContract } = useDeployedContractInfo("ClawdFomo3D");

  // ============ Read Contract State ============
  const { data: currentRound } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "currentRound",
  });

  const { data: pot } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "pot",
  });

  const { data: totalKeys } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "totalKeys",
  });

  const { data: lastBuyer } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "lastBuyer",
  });

  const { data: currentKeyPrice } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "currentKeyPrice",
  });

  const { data: timeRemaining } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "timeRemaining",
  });

  const { data: totalBurned } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "totalBurned",
  });

  const { data: costForKeys } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "getCostForKeys",
    args: [BigInt(numKeys || "1")],
  });

  const { data: playerKeys } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "getPlayerKeys",
    args: [currentRound, connectedAddress],
  });

  const { data: playerDividends } = useScaffoldReadContract({
    contractName: "ClawdFomo3D",
    functionName: "dividendsOf",
    args: [currentRound, connectedAddress],
  });

  // ============ Write Functions ============
  const { writeContractAsync: writeBuyKeys } = useScaffoldWriteContract({
    contractName: "ClawdFomo3D",
  });

  const { writeContractAsync: writeEndRound } = useScaffoldWriteContract({
    contractName: "ClawdFomo3D",
  });

  const { writeContractAsync: writeClaim } = useScaffoldWriteContract({
    contractName: "ClawdFomo3D",
  });

  // ERC20 approve via wagmi directly
  const { writeContractAsync: writeApprove } = useWriteContract();

  // ============ Timer Countdown ============
  useEffect(() => {
    if (timeRemaining === undefined) {
      setTimeLeft("--:--");
      return;
    }
    const seconds = Number(timeRemaining);
    if (seconds <= 0) {
      setTimeLeft("00:00");
      return;
    }
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    setTimeLeft(`${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`);
  }, [timeRemaining]);

  // ============ Helpers ============
  const formatClawd = (val: bigint | undefined) => {
    if (!val) return "0";
    const num = Number(formatUnits(val, 18));
    if (num > 1_000_000) return (num / 1_000_000).toFixed(2) + "M";
    if (num > 1_000) return (num / 1_000).toFixed(2) + "K";
    return num.toFixed(0);
  };

  const shortAddr = (addr: string | undefined) => {
    if (!addr || addr === "0x0000000000000000000000000000000000000000") return "Nobody";
    return addr.slice(0, 6) + "..." + addr.slice(-4);
  };

  const isRoundOver = timeRemaining !== undefined && timeRemaining === 0n;
  const fomo3dAddress = fomo3dContract?.address;

  return (
    <div className="flex flex-col items-center min-h-screen pt-8 px-4">
      {/* Title */}
      <div className="text-center mb-8">
        <h1 className="text-5xl font-bold mb-2">🔥 ClawdFomo3D</h1>
        <p className="text-lg opacity-70">Last buyer wins. $CLAWD burns every round.</p>
      </div>

      {/* Main Game Card */}
      <div className="bg-base-200 rounded-3xl p-8 w-full max-w-lg shadow-xl mb-6">
        {/* Round Info */}
        <div className="text-center mb-6">
          <div className="text-sm opacity-60 mb-1">ROUND {currentRound?.toString() || "1"}</div>

          {/* Timer */}
          <div
            className={`text-6xl font-mono font-bold mb-4 ${isRoundOver ? "text-error animate-pulse" : "text-primary"}`}
          >
            {isRoundOver ? "ENDED" : timeLeft}
          </div>

          {/* Pot */}
          <div className="stat bg-base-100 rounded-2xl px-6 py-4 inline-block">
            <div className="stat-title">💰 POT</div>
            <div className="stat-value text-secondary">{formatClawd(pot)} $CLAWD</div>
          </div>
        </div>

        {/* Stats Grid */}
        <div className="grid grid-cols-2 gap-3 mb-6">
          <div className="bg-base-100 rounded-xl p-3 text-center">
            <div className="text-xs opacity-60">KEY PRICE</div>
            <div className="font-bold">{formatClawd(currentKeyPrice)}</div>
          </div>
          <div className="bg-base-100 rounded-xl p-3 text-center">
            <div className="text-xs opacity-60">TOTAL KEYS</div>
            <div className="font-bold">{totalKeys?.toString() || "0"}</div>
          </div>
          <div className="bg-base-100 rounded-xl p-3 text-center">
            <div className="text-xs opacity-60">🔥 TOTAL BURNED</div>
            <div className="font-bold text-error">{formatClawd(totalBurned)}</div>
          </div>
          <div className="bg-base-100 rounded-xl p-3 text-center">
            <div className="text-xs opacity-60">👑 LAST BUYER</div>
            <div className="font-bold text-xs">{shortAddr(lastBuyer)}</div>
          </div>
        </div>

        {/* Buy Keys */}
        {!isRoundOver ? (
          <div className="mb-4">
            <div className="flex gap-2 mb-2">
              <input
                type="number"
                min="1"
                value={numKeys}
                onChange={e => setNumKeys(e.target.value)}
                className="input input-bordered flex-1"
                placeholder="# keys"
              />
              <button
                className="btn btn-primary btn-lg"
                disabled={isBuying || !connectedAddress}
                onClick={async () => {
                  if (!costForKeys || !connectedAddress) return;
                  setIsBuying(true);
                  try {
                    await writeBuyKeys({
                      functionName: "buyKeys",
                      args: [BigInt(numKeys || "1")],
                    });
                  } catch (e) {
                    console.error("Buy failed:", e);
                  }
                  setIsBuying(false);
                }}
              >
                {isBuying ? "⏳" : "🎰 BUY"}
              </button>
            </div>
            <div className="text-sm opacity-60 text-center mb-2">
              Cost: {formatClawd(costForKeys)} $CLAWD (incl. 10% burn)
            </div>
            {fomo3dAddress && (
              <button
                className="btn btn-outline btn-sm w-full mt-1"
                disabled={isApproving || !costForKeys || !connectedAddress}
                onClick={async () => {
                  if (!costForKeys || !fomo3dAddress) return;
                  setIsApproving(true);
                  try {
                    // Approve a generous amount so users don't re-approve each time
                    const approveAmount = costForKeys * 100n;
                    await writeApprove({
                      address: CLAWD_TOKEN,
                      abi: erc20Abi,
                      functionName: "approve",
                      args: [fomo3dAddress, approveAmount],
                    });
                  } catch (e) {
                    console.error("Approve failed:", e);
                  }
                  setIsApproving(false);
                }}
              >
                {isApproving ? "Approving..." : "✅ Approve $CLAWD (do this first!)"}
              </button>
            )}
          </div>
        ) : (
          <button
            className="btn btn-error btn-lg w-full mb-4"
            onClick={async () => {
              try {
                await writeEndRound({
                  functionName: "endRound",
                });
              } catch (e) {
                console.error("End round failed:", e);
              }
            }}
          >
            🏆 END ROUND & CROWN WINNER
          </button>
        )}
      </div>

      {/* Player Stats */}
      {connectedAddress && (
        <div className="bg-base-200 rounded-3xl p-6 w-full max-w-lg shadow-xl mb-6">
          <h2 className="text-xl font-bold mb-4 text-center">Your Stats</h2>
          <div className="grid grid-cols-2 gap-3 mb-4">
            <div className="bg-base-100 rounded-xl p-3 text-center">
              <div className="text-xs opacity-60">YOUR KEYS</div>
              <div className="font-bold text-lg">{playerKeys?.toString() || "0"}</div>
            </div>
            <div className="bg-base-100 rounded-xl p-3 text-center">
              <div className="text-xs opacity-60">DIVIDENDS</div>
              <div className="font-bold text-lg">{formatClawd(playerDividends)}</div>
            </div>
          </div>
          {playerDividends && playerDividends > 0n && (
            <button
              className="btn btn-success w-full"
              onClick={async () => {
                try {
                  await writeClaim({
                    functionName: "claimDividends",
                    args: [currentRound],
                  });
                } catch (e) {
                  console.error("Claim failed:", e);
                }
              }}
            >
              💰 Claim {formatClawd(playerDividends)} $CLAWD
            </button>
          )}
        </div>
      )}

      {/* How It Works */}
      <div className="bg-base-200 rounded-3xl p-6 w-full max-w-lg shadow-xl mb-8">
        <h2 className="text-xl font-bold mb-3 text-center">How It Works</h2>
        <div className="space-y-2 text-sm">
          <p>
            🎰 <strong>Buy keys</strong> with $CLAWD. Each buy resets the timer.
          </p>
          <p>
            👑 <strong>Last buyer</strong> when timer hits zero wins 40% of the pot.
          </p>
          <p>
            🔥 <strong>10% burned</strong> on every buy + <strong>30% burned</strong> at round end.
          </p>
          <p>
            💰 <strong>25% of pot</strong> distributed to all key holders as dividends.
          </p>
          <p>
            ⚡ <strong>Anti-snipe:</strong> Buys in last 2 min only extend timer by 2 min.
          </p>
        </div>
      </div>
    </div>
  );
};

export default Home;
