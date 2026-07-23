import * as React from "react";

export interface GlanceCardProps {
  /** Title shown in the header, in secondary uppercase-tracked text. */
  title: string;
  /** Optional leading glyph (an emoji or short symbol) in a tinted chip. */
  icon?: React.ReactNode;
  /** The glance content — typically Stat, Badge, or a small readout. */
  children?: React.ReactNode;
}

/**
 * The signature glance surface — a compact, raised card with a titled header
 * and a small content body. This is the widget shell every glance is built in;
 * fill it with a Stat, a Badge, or a short list.
 */
export function GlanceCard({ title, icon, children }: GlanceCardProps) {
  return (
    <div className="gk-glancecard">
      <div className="gk-glancecard__header">
        {icon != null && <span className="gk-glancecard__icon">{icon}</span>}
        <span className="gk-glancecard__title">{title}</span>
      </div>
      <div className="gk-glancecard__body">{children}</div>
    </div>
  );
}
