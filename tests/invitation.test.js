'use strict';
const { makeTestBE } = require('./lib/testBE');

const H = 'hotel-inv-001';

describe('Invitation utilisateur', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('inviteUser retourne success:true', async () => {
    const result = await be.inviteUser(H, 'jean.martin@hotel.fr', 'Jean Martin', 'reception');
    expect(result.success).toBe(true);
    expect(result.user_id).toBeTruthy();
  });

  test('listAccess retourne la liste des utilisateurs', async () => {
    const list = await be.listAccess(H);
    expect(Array.isArray(list)).toBe(true);
    expect(list.length).toBeGreaterThan(0);
    expect(list[0]).toHaveProperty('email');
    expect(list[0]).toHaveProperty('role');
  });

  test('updateAccess ne lève pas d\'erreur', async () => {
    await expect(be.updateAccess(H, 'u1', 'gouvernante')).resolves.not.toThrow();
  });

  test('revokeAccess ne lève pas d\'erreur', async () => {
    await expect(be.revokeAccess(H, 'u2')).resolves.not.toThrow();
  });
});
