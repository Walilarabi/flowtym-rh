'use strict';
/**
 * Reproduction de la logique PERMS / canSee / canFicheFull
 * depuis index.html — sans DOM, testable en Node.
 */

const PERMS = {
  direction:        { tabs:'all', ficheFull:true,  manageUsers:true  },
  admin_hotel:      { tabs:'all', ficheFull:true,  manageUsers:true  },
  comptabilite:     { tabs:['dashboard','reporting','personnel','contracts','absences','pointage','tracking','payroll','equipment'], ficheFull:true, manageUsers:false },
  revenue_manager:  { tabs:['dashboard','reporting'], ficheFull:false, manageUsers:false },
  reception:        { tabs:['dashboard','planning','personnel','absences'], ficheFull:false, manageUsers:false },
  gouvernante:      { tabs:['dashboard','planning','personnel','absences'], ficheFull:false, manageUsers:false },
  maintenance:      { tabs:['dashboard','planning','personnel','absences'], ficheFull:false, manageUsers:false },
  breakfast:        { tabs:['dashboard','planning','personnel','absences'], ficheFull:false, manageUsers:false },
  femme_de_chambre: { tabs:['dashboard','planning'], ficheFull:false, manageUsers:false },
};

function canSee(role, tab) {
  const p = PERMS[role];
  if (!p) return false;
  if (p.tabs === 'all') return true;
  return p.tabs.includes(tab);
}

function canFicheFull(role) { return PERMS[role]?.ficheFull === true; }
function canManageUsers(role) { return PERMS[role]?.manageUsers === true; }

module.exports = { PERMS, canSee, canFicheFull, canManageUsers };
