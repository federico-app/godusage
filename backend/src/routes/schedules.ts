import type { Handler } from "../context";
import { forbidden, json, notFound, readJSONObject } from "../http";
import { defaultSchedule, loadMemberHours, parseSchedule, storeSchedule } from "../schedules";
import { requireUser } from "../session";
import { storedWorkingDays } from "../workingDays";

/**
 * GET /v1/teams/:teamID/schedules — every counted member's working hours (the team default for those
 * who never set theirs) and their Mac's time zone, for any member. Members whose usage doesn't count
 * (viewers) are left out: their hours pace nothing.
 */
export const getSchedules: Handler = async ({ request, env, params }) => {
  const user = await requireUser(request, env.db);
  const teamID = params.teamID!;
  const members = await env.db.query<{ user_id: string; display_name: string; role: string; counts_usage: boolean; working_days: string }>(
    `SELECT m.user_id, u.display_name, m.role, m.counts_usage, t.working_days FROM team_members m
     JOIN users u ON u.id = m.user_id JOIN teams t ON t.id = m.team_id WHERE m.team_id = $1 ORDER BY u.display_name, m.user_id`,
    [teamID],
  );
  const me = members.find((member) => member.user_id === user.id);
  if (!me) throw notFound("Team not found.");
  const counted = members.filter((member) => member.counts_usage);
  const hours = await loadMemberHours(env.db, teamID, counted.map((member) => member.user_id));
  const teamDays = storedWorkingDays(me.working_days);
  return json({
    defaultSchedule: defaultSchedule(teamDays),
    canEditOthers: me.role === "owner",
    members: counted.map((member) => {
      const stored = hours.get(member.user_id);
      return {
        userID: member.user_id,
        displayName: member.display_name,
        schedule: stored?.schedule ?? defaultSchedule(teamDays),
        isDefault: !stored?.schedule,
        timeZone: stored?.timeZone ?? null,
      };
    }),
  });
};

/**
 * PUT /v1/teams/:teamID/members/:userID/schedule { schedule: { days, start, end, breakStart?, breakEnd? } | null }
 * — sets a member's working hours in this team (null goes back to the team default). Members set their
 * own; owners set anyone's in their team. Other teams keep the member's hours there.
 */
export const putSchedule: Handler = async ({ request, env, params, deps }) => {
  const user = await requireUser(request, env.db);
  const teamID = params.teamID!;
  const target = params.userID!;
  const rows = await env.db.query<{ user_id: string; role: string }>(
    "SELECT user_id, role FROM team_members WHERE team_id = $1 AND user_id = ANY($2::text[])",
    [teamID, [user.id, target]],
  );
  const me = rows.find((row) => row.user_id === user.id);
  if (!me || !rows.some((row) => row.user_id === target)) throw notFound("Member not found.");
  if (target !== user.id && me.role !== "owner") throw forbidden("Only team owners can change someone else's working hours.");
  const body = await readJSONObject(request);
  const schedule = body.schedule === null ? null : parseSchedule(body.schedule);
  await storeSchedule(env.db, teamID, target, schedule, deps.now());
  await env.cache.forgetTeams([teamID], "plans|");
  return json({ schedule: schedule ?? null });
};
