export function readinessPercent(project){return Number(project.active_lines)>0?`${(100*Number(project.ready_lines)/Number(project.active_lines)).toFixed(1)}%`:null;}
