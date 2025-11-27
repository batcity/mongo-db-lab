try {
  rs.initiate();
} catch (e) {
  // ignore errors (node not ready yet or already initiated)
}
