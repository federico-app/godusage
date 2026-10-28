import type { Queryable } from "./db";
import { sameLabel, type PlanChange } from "./planChanges";

/** A member's latest detected plan for a provider, across their Macs. */
export interface Detection {
  userID: string;
  displayName: string;
  provider: string;
  plan: string;
  /** When a Mac first sent this label (ISO 8601). */
  detectedAt: string;
  /** The same moment as that Mac's local calendar day. */
  detectedOn: string;
}

/** A covered member whose Mac detects another plan than the one a team plan is linked to. */
export interface Mismatch {
  userID: string;
  displayName: string;
  detectedPlan: string;
  detectedAt: string;
  detectedOn: string;
}

export interface DetectedPlanInput {
  provider: string;
  plan: string;
}

/** The team's members' latest detected plan per provider: of their Macs, the one that changed last. */
export async function teamDetections(db: Queryable, teamID: string): Promise<Detection[]> {
  const rows = await db.query<{ user_id: string; display_name: string; provider: string; plan: string; detected_at: string; detected_on: string }>(
    `SELECT DISTINCT ON (d.user_id, d.provider) d.user_id, u.display_name, d.provider, d.plan, d.detected_at, d.detected_on
     FROM detected_plans d
     JOIN team_members m ON m.user_id = d.user_id AND m.team_id = $1 AND m.counts_usage
     JOIN users u ON u.id = d.user_id
     ORDER BY d.user_id, d.provider, d.detected_at DESC, d.device_id`,
    [teamID],
  );
  return rows.map((row) => ({
    userID: row.user_id,
    displayName: row.display_name,
    provider: row.provider,
    plan: row.plan,
    detectedAt: row.detected_at,
    detectedOn: row.detected_on,
  }));
}

/**
 * The covered members whose latest detected plan differs from the plan's linked label. A label the
 * owner ignored, or that a change in this cycle or later already names, is not a mismatch. A plan
 * with no linked label never flags.
 */
export function planMismatches(
  plan: { provider: string; detectedPlan: string | null; ignoredPlans: string[]; changes: PlanChange[] },
  covered: (userID: string) => boolean,
  cycleFrom: string,
  detections: Detection[],
): Mismatch[] {
  if (plan.detectedPlan === null) return [];
  const accepted = [plan.detectedPlan, ...plan.ignoredPlans, ...plan.changes.filter((change) => change.effectiveFrom >= cycleFrom).map((change) => change.name)];
  return detections
    .filter((detection) => detection.provider === plan.provider && covered(detection.userID))
    .filter((detection) => !accepted.some((label) => sameLabel(label, detection.plan)))
    .map(({ userID, displayName, plan: detectedPlan, detectedAt, detectedOn }) => ({ userID, displayName, detectedPlan, detectedAt, detectedOn }));
}

/**
 * Keeps this Mac's detected plans in step with an upload that carries them: a new or changed label
 * is stamped with now, an unchanged one keeps its stamp, and providers the upload no longer names are
 * dropped. Returns the rows it changed.
 */
export async function storeDetectedPlans(
  tx: Queryable,
  userID: string,
  deviceID: string,
  plans: DetectedPlanInput[],
  now: Date,
  localDay: string,
): Promise<number> {
  const rows = JSON.stringify(plans);
  const upserted = await tx.run(
    `INSERT INTO detected_plans (user_id, device_id, provider, plan, detected_at, detected_on)
     SELECT $1, $2, r.provider, r.plan, $4, $5 FROM jsonb_to_recordset($3::jsonb) AS r(provider text, plan text)
     ON CONFLICT (user_id, device_id, provider) DO UPDATE SET plan = excluded.plan, detected_at = excluded.detected_at, detected_on = excluded.detected_on
     WHERE detected_plans.plan IS DISTINCT FROM excluded.plan`,
    [userID, deviceID, rows, now.toISOString(), localDay],
  );
  const removed = await tx.run(
    `DELETE FROM detected_plans d WHERE d.user_id = $1 AND d.device_id = $2
     AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset($3::jsonb) AS r(provider text) WHERE r.provider = d.provider)`,
    [userID, deviceID, rows],
  );
  return upserted + removed;
}
