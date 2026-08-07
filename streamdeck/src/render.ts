import { accentHex } from "./protocol";

/**
 * Keys are drawn as SVG rather than set with `setTitle`, because a Videohub key
 * has to show three things at once — the source, the destination it lands on,
 * and whether that route is currently live — and a title alone cannot separate
 * them. Drawing also lets the key carry the same accent color the operator
 * already assigned to that port in the app, so the deck and the screen agree.
 */
export type KeyFace = {
	/** Large center line: usually the source name. */
	primary: string;
	/** Small top line: usually the destination, omitted when it adds nothing. */
	secondary?: string;
	/** Accent name from the app, e.g. "blue". */
	color?: string;
	/** Route is currently live on the router. */
	live: boolean;
	/** Shown bottom-right for multi-step keys, e.g. "2/4". */
	badge?: string;
	/** Draws the key dimmed with a slash, for "app not running". */
	unavailable?: boolean;
};

const SIZE = 144;

function escapeXML(value: string): string {
	return value
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;");
}

/**
 * Splits a label across at most `maxLines`, breaking on spaces where possible.
 * Port names on set are things like "Witcam 1 - FA" and "BBDesk3 Right", which
 * are unreadable on one line at key size.
 */
function wrap(text: string, maxChars: number, maxLines: number): string[] {
	const words = text.trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) {
		return [];
	}

	const lines: string[] = [];
	let current = "";
	for (const word of words) {
		const candidate = current.length === 0 ? word : `${current} ${word}`;
		if (candidate.length <= maxChars) {
			current = candidate;
			continue;
		}
		if (current.length > 0) {
			lines.push(current);
			current = word;
		} else {
			// A single word longer than the line: hard-break it rather than
			// letting it overflow the key.
			lines.push(word.slice(0, maxChars));
			current = word.slice(maxChars);
		}
		if (lines.length === maxLines) {
			break;
		}
	}
	if (lines.length < maxLines && current.length > 0) {
		lines.push(current);
	}

	if (lines.length === maxLines) {
		const last = lines[maxLines - 1]!;
		const consumed = lines.join(" ").length;
		if (consumed < text.trim().length) {
			lines[maxLines - 1] = `${last.slice(0, Math.max(0, maxChars - 1))}…`;
		}
	}
	return lines;
}

export function renderKey(face: KeyFace): string {
	const accent = accentHex(face.color);
	const background = face.live ? accent : "#1c1c1e";
	const border = face.live ? "#ffffff" : accent;
	const borderWidth = face.live ? 6 : 3;
	const primaryFill = face.live ? "#ffffff" : "#f2f2f7";
	const opacity = face.unavailable ? 0.35 : 1;

	const hasSecondary = Boolean(face.secondary && face.secondary.length > 0);
	const primaryLines = wrap(face.primary, 11, hasSecondary ? 2 : 3);
	const lineHeight = 22;
	const centerY = hasSecondary ? 88 : 78;
	const startY = centerY - ((primaryLines.length - 1) * lineHeight) / 2;

	const primaryText = primaryLines
		.map(
			(line, index) =>
				`<text x="${SIZE / 2}" y="${startY + index * lineHeight}" font-family="system-ui, -apple-system, Helvetica, sans-serif" font-size="20" font-weight="600" fill="${primaryFill}" text-anchor="middle" dominant-baseline="middle">${escapeXML(line)}</text>`
		)
		.join("");

	const secondaryText = hasSecondary
		? `<text x="${SIZE / 2}" y="30" font-family="system-ui, -apple-system, Helvetica, sans-serif" font-size="14" font-weight="500" fill="${face.live ? "#ffffffcc" : "#9a9aa0"}" text-anchor="middle" dominant-baseline="middle">${escapeXML(wrap(face.secondary!, 15, 1)[0] ?? "")}</text>`
		: "";

	const badgeText = face.badge
		? `<text x="${SIZE - 10}" y="${SIZE - 10}" font-family="system-ui, -apple-system, Helvetica, sans-serif" font-size="13" font-weight="600" fill="${face.live ? "#ffffffcc" : "#8e8e93"}" text-anchor="end">${escapeXML(face.badge)}</text>`
		: "";

	const unavailableMark = face.unavailable
		? `<line x1="24" y1="24" x2="${SIZE - 24}" y2="${SIZE - 24}" stroke="#8e8e93" stroke-width="5" stroke-linecap="round" />`
		: "";

	const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">
<rect x="0" y="0" width="${SIZE}" height="${SIZE}" rx="18" fill="#000000" />
<g opacity="${opacity}">
<rect x="${borderWidth / 2}" y="${borderWidth / 2}" width="${SIZE - borderWidth}" height="${SIZE - borderWidth}" rx="16" fill="${background}" stroke="${border}" stroke-width="${borderWidth}" />
${secondaryText}${primaryText}${badgeText}${unavailableMark}
</g>
</svg>`;

	return `data:image/svg+xml;charset=utf8,${encodeURIComponent(svg)}`;
}
