export class Greeter {
  constructor(readonly name: string) {}

  greet(): string {
    return `Hello, ${this.name}`;
  }
}
