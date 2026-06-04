'use strict';
const { makeTestBE } = require('./lib/testBE');

const H = 'hotel-emp-001';

describe('Employés — CRUD + photo', () => {
  let be;
  beforeEach(() => { be = makeTestBE(); });

  test('addEmployee crée un employé avec id', async () => {
    const emp = await be.addEmployee(H, { first_name: 'Alice', last_name: 'Dupont', contract_type: 'CDI', active: true });
    expect(emp.id).toBeTruthy();
    expect(emp.hotel_id).toBe(H);
    expect(emp.first_name).toBe('Alice');
  });

  test('listEmployees filtre par hotel_id', async () => {
    await be.addEmployee(H, { first_name: 'Alice', last_name: 'A', active: true });
    await be.addEmployee('autre-hotel', { first_name: 'Bob', last_name: 'B', active: true });
    const list = await be.listEmployees(H);
    expect(list.length).toBe(1);
    expect(list[0].first_name).toBe('Alice');
  });

  test('updateEmployee met à jour les champs', async () => {
    const emp = await be.addEmployee(H, { first_name: 'Alice', last_name: 'A', active: true });
    await be.updateEmployee(emp.id, { role: 'Réceptionniste' });
    const list = await be.listEmployees(H);
    expect(list[0].role).toBe('Réceptionniste');
  });

  test('updateEmployee avec photo_url stocke la valeur', async () => {
    const emp = await be.addEmployee(H, { first_name: 'Alice', last_name: 'A', active: true });
    const fakeDataUrl = 'data:image/jpeg;base64,/9j/fake==';
    await be.updateEmployee(emp.id, { photo_url: fakeDataUrl });
    const list = await be.listEmployees(H);
    expect(list[0].photo_url).toBe(fakeDataUrl);
  });

  test('updateEmployee photo_url=null supprime la photo', async () => {
    const emp = await be.addEmployee(H, { first_name: 'Alice', last_name: 'A', active: true, photo_url: 'data:image/jpeg;base64,abc' });
    await be.updateEmployee(emp.id, { photo_url: null });
    const list = await be.listEmployees(H);
    expect(list[0].photo_url).toBeNull();
  });

  test('updateEmployee lève une erreur si id inconnu', async () => {
    await expect(be.updateEmployee('id-inexistant', { first_name: 'X' })).rejects.toThrow();
  });
});
