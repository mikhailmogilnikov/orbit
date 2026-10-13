export class Greeter {
  constructor(readonly name: string) {}

  greet(): string {
    return `Hello, ${this.name}`;
  }
}

export function shout(text: string): string {
  return text.toUpperCase();
}
