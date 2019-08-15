using System;
using System.Threading;

namespace Techsola
{
    internal static class On
    {
        public static IDisposable Dispose(Action action) => new OnDisposeAction(action);

        private sealed class OnDisposeAction : IDisposable
        {
            private Action? action;

            public OnDisposeAction(Action action)
            {
                this.action = action ?? throw new ArgumentNullException(nameof(action));
            }

            public void Dispose() => Interlocked.Exchange(ref action, null)?.Invoke();
        }
    }
}
