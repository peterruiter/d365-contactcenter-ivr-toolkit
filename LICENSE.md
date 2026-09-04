# Licence

MIT License

Copyright (c) 2026 Power Pete

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Operational notes

Not legal terms, but worth knowing before you deploy this:

- Live queue metrics read internal Dynamics 365 platform tables that carry no API
  guarantee from Microsoft. The toolkit degrades rather than fails when those change,
  and a health check detects it, but you should know it is there.
- Queue resolution, opening hours and callbacks use supported schema.
- Microsoft does not support this toolkit. There is no vendor backing it; support is
  whatever the project maintainers and community provide. See
  [ALM and support](docs/10-alm-and-support.md).

## Third party components

| Component | Licence | Use |
|---|---|---|
| Newtonsoft.Json | MIT | Serialisation in the plugin, merged into the assembly |
| Microsoft.CrmSdk.CoreAssemblies | Microsoft SDK licence | Plugin base types |
| xunit, FakeXrmEasy | MIT / dual | Test only, not shipped |
| Azure.Identity, Microsoft.Identity.Web | MIT | MCP server only |

FakeXrmEasy is dual licensed. Check the current terms before using it commercially.
