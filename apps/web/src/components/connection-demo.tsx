"use client";

import { useState } from "react";
import { PlugIcon, LockKeyIcon, ArrowCounterClockwiseIcon } from "@phosphor-icons/react";

export function ConnectionDemo() {
  const [removed, setRemoved] = useState(false);
  return <div className="connection-demo">
    <div className="demo-label">Interactive explanation</div>
    <div className="demo-track" data-removed={removed} aria-hidden="true">
      <div className="demo-node demo-device"><PlugIcon size={38} weight="light" /></div><div className="connection-line" />
      <div className="demo-node"><LockKeyIcon size={38} weight={removed ? "fill" : "light"} /></div>
    </div>
    <div className="demo-state" role="status" aria-live="polite" aria-atomic="true">
      <strong>{removed ? "Lock requested" : "USB connection selected"}</strong>
      <p>{removed ? "That is a request, not confirmation that macOS locked. Reconnecting requires a fresh selection." : "The planned trigger is the end of this connection. Try the demonstration below."}</p>
    </div>
    <button className="button secondary" onClick={() => setRemoved(!removed)}>{removed ? <><ArrowCounterClockwiseIcon size={18} aria-hidden="true" /> Reset demo</> : "Simulate removal"}</button>
    <p className="demo-note">Browser simulation only. No device access or screen locking.</p>
  </div>;
}
