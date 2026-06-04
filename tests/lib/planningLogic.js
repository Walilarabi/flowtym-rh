/**
 * Détecte les infractions légales dans le planning d'un mois.
 * @param {Array} rows      - lignes de planning [{employee_id, day:'YYYY-MM-DD', status, shift_label, shift_start, shift_end, break_minutes}]
 * @param {number} y        - année
 * @param {number} m        - mois 0-indexé
 * @param {Object} deps     - {cmap, dimFn, isoFn}
 *   cmap   = {CODE: {cat:'worked'|'abs'|'paid'|'holiday'}}
 *   dimFn  = (y,m) => nombre de jours du mois
 *   isoFn  = (y,m,d) => 'YYYY-MM-DD'
 * @returns {Array} alerts [{employee_id, day, type, message}]
 *   types: '7_consecutive' | 'shift_on_absence' | 'excessive_duration'
 */
function computeLegalAlerts(rows, y, m, { cmap, dimFn, isoFn }) {
  const alerts = [];
  const nd = dimFn(y, m);

  // Groupe par employé
  const byEmp = new Map();
  rows.forEach(r => {
    if (!byEmp.has(r.employee_id)) byEmp.set(r.employee_id, new Map());
    byEmp.get(r.employee_id).set(r.day, r);
  });

  byEmp.forEach((dayMap, eid) => {
    // Check 1 : 7 jours consécutifs travaillés (cat='worked')
    let streak = 0, streakStart = null;
    for (let d = 1; d <= nd; d++) {
      const day = isoFn(y, m, d);
      const row = dayMap.get(day);
      const cat = row ? (cmap[row.status]?.cat || '') : '';
      if (cat === 'worked') {
        streak++;
        if (streak === 1) streakStart = day;
        if (streak === 7) {
          alerts.push({ employee_id: eid, day: streakStart, type: '7_consecutive', message: '7 jours consécutifs travaillés' });
        }
      } else {
        streak = 0; streakStart = null;
      }
    }

    // Check 2 : shift sur absence (cat=abs ou paid + shift_label)
    dayMap.forEach((row, day) => {
      const cat = cmap[row.status]?.cat || '';
      if ((cat === 'abs' || cat === 'paid') && row.shift_label) {
        alerts.push({ employee_id: eid, day, type: 'shift_on_absence', message: `Shift ${row.shift_label} incompatible avec ${row.status}` });
      }
    });

    // Check 3 : durée quotidienne excessive > 10h (shift_start + shift_end requis)
    dayMap.forEach((row, day) => {
      if (row.status !== 'P' || !row.shift_start || !row.shift_end) return;
      const [sh, sm] = String(row.shift_start).split(':').map(Number);
      const [eh, em] = String(row.shift_end).split(':').map(Number);
      let durationMin = (eh * 60 + em) - (sh * 60 + sm);
      if (durationMin < 0) durationMin += 24 * 60; // poste de nuit
      durationMin -= (row.break_minutes || 0);
      if (durationMin > 10 * 60) {
        alerts.push({ employee_id: eid, day, type: 'excessive_duration', message: `Durée excessive : ${Math.round(durationMin / 6) / 10}h` });
      }
    });
  });

  return alerts;
}

/**
 * Détecte les jours en sous-effectif par rapport aux règles de couverture.
 * @param {Array}  rows          - planningRows [{employee_id, day, status, shift_label}]
 * @param {Array}  coverageRules - [{department, shift_label, day_of_week, min_staff_base, active}]
 * @param {Map}    staffDeptMap  - Map<employee_id, department>
 * @param {number} y             - année
 * @param {number} m             - mois 0-indexé
 * @param {Object} deps          - {dimFn, isoFn}
 * @returns {Array} alerts [{day, department, shift, required, actual, type:'understaffed'}]
 */
function computeCoverageAlerts(rows, coverageRules, staffDeptMap, y, m, { dimFn, isoFn }) {
  const alerts = [];
  const nd = dimFn(y, m);
  const activeRules = coverageRules.filter(r => r.active !== false);

  activeRules.forEach(rule => {
    for (let d = 1; d <= nd; d++) {
      const wd = new Date(y, m, d).getDay(); // 0=dim…6=sam
      const wdMon = wd === 0 ? 6 : wd - 1;  // converti en 0=lun…6=dim

      if (rule.day_of_week !== null && rule.day_of_week !== undefined && rule.day_of_week !== wdMon) continue;

      const day = isoFn(y, m, d);
      const count = rows.filter(r =>
        r.day === day &&
        r.status === 'P' &&
        r.shift_label === rule.shift_label &&
        staffDeptMap.get(r.employee_id) === rule.department
      ).length;

      if (count < rule.min_staff_base) {
        alerts.push({ day, department: rule.department, shift: rule.shift_label, required: rule.min_staff_base, actual: count, type: 'understaffed' });
      }
    }
  });

  return alerts;
}

module.exports = { computeLegalAlerts, computeCoverageAlerts };
