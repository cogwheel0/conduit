import {build} from 'esbuild';
import {readFile} from 'node:fs/promises';

await build({
  entryPoints: ['viewer.js'], bundle: true, minify: true, format: 'esm',
  legalComments: 'linked', outfile: '../../assets/computer/viewer.js',
  plugins: [{
    name: 'server-rendered-cursor',
    setup(build) {
      build.onLoad({filter: /@novnc\/novnc\/core\/rfb\.js$/}, async ({path}) => {
        let contents = await readFile(path, 'utf8');
        // Ask the VNC server to include its actual pointer in the framebuffer.
        // A client-side cursor follows the viewer, hiding agent movement in Watch.
        // Fail closed on dependency changes; never silently lose this behavior.
        for (const encoding of ['VMwareCursor', 'Cursor']) {
          const line = `encs.push(encodings.pseudoEncoding${encoding});`;
          if (contents.split(line).length !== 2) throw new Error('noVNC cursor negotiation changed');
          contents = contents.replace(line, '');
        }
        return {contents, loader: 'js'};
      });
    },
  }],
});
